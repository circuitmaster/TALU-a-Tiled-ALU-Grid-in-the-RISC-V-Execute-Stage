//===- TALUMap.cpp - extract TALU grid kernels from annotated C loops -----===//
// An out-of-tree LLVM pass (new PM) that recognizes functions annotated
// `__attribute__((annotate("talu")))`, finds their innermost loop, extracts the
// loop-body expression DAG over the streamed loads + constants, classifies the
// loop as a map or a reduction, and writes a kernel descriptor as JSON. The
// Python mapper (mapc.py) turns that descriptor into a grid configuration
// (GCFG/GCFGI/GFLOW). See README.md.
//
// Build:  make          (uses llvm-config-20)
// Run:    opt-20 -load-pass-plugin ./TALUMap.so -passes=talu-map -disable-output in.ll
//===----------------------------------------------------------------------===//
#include "llvm/IR/Module.h"
#include "llvm/IR/Function.h"
#include "llvm/IR/Instructions.h"
#include "llvm/IR/IntrinsicInst.h"
#include "llvm/IR/Constants.h"
#include "llvm/IR/PatternMatch.h"
#include "llvm/Analysis/LoopInfo.h"
#include "llvm/Passes/PassBuilder.h"
#include "llvm/Passes/PassPlugin.h"
#include "llvm/Support/raw_ostream.h"
#include "llvm/Support/FileSystem.h"
#include <map>
#include <string>
#include <vector>

using namespace llvm;
using namespace llvm::PatternMatch;

namespace {

// Map an argument pointer Value to a stable stream index (order of first use).
struct StreamMap {
  std::vector<const Value *> ptrs;
  int idOf(const Value *p) {
    for (size_t i = 0; i < ptrs.size(); i++)
      if (ptrs[i] == p) return (int)i;
    ptrs.push_back(p);
    return (int)ptrs.size() - 1;
  }
};

static std::string jstr(StringRef s) { return ("\"" + s + "\"").str(); }

// Recursively emit a JSON node for a value computed inside the loop.
// Leaves: {"load":<streamPtrArgNo>}, {"const":<int>}, {"acc":true}.
// Nodes:  {"op":"add|sub|mul|and|or|xor|shl|min|max","a":..,"b":..}.
static bool emitNode(Value *V, Loop *L, PHINode *IV, PHINode *Acc,
                     StreamMap &SM, std::map<const Value *, int> &argNo,
                     std::string &out, int depth) {
  if (depth > 12) return false;
  if (Acc && V == Acc) { out += "{\"acc\":true}"; return true; }

  if (auto *C = dyn_cast<ConstantInt>(V)) {
    out += "{\"const\":" + std::to_string(C->getSExtValue()) + "}";
    return true;
  }

  if (auto *LD = dyn_cast<LoadInst>(V)) {
    // pointer must be a GEP of a function-argument base indexed by the IV
    auto *GEP = dyn_cast<GetElementPtrInst>(LD->getPointerOperand());
    if (!GEP) return false;
    const Value *base = GEP->getPointerOperand();
    auto it = argNo.find(base);
    if (it == argNo.end()) return false;               // not a stream arg
    out += "{\"load\":" + std::to_string(it->second) + "}";
    (void)SM;
    return true;
  }

  // min/max as LLVM intrinsics (clang canonicalizes a<b?a:b to these)
  if (auto *II = dyn_cast<IntrinsicInst>(V)) {
    const char *iop = nullptr;
    switch (II->getIntrinsicID()) {
      case Intrinsic::smin: iop = "min"; break;
      case Intrinsic::smax: iop = "max"; break;
      default: return false;
    }
    std::string sa, sb;
    if (!emitNode(II->getArgOperand(0), L, IV, Acc, SM, argNo, sa, depth + 1)) return false;
    if (!emitNode(II->getArgOperand(1), L, IV, Acc, SM, argNo, sb, depth + 1)) return false;
    out += "{\"op\":" + jstr(iop) + ",\"a\":" + sa + ",\"b\":" + sb + "}";
    return true;
  }

  // min/max via select(icmp, a, b)
  Value *A, *B; ICmpInst::Predicate P;
  if (auto *Sel = dyn_cast<SelectInst>(V)) {
    if (auto *Cmp = dyn_cast<ICmpInst>(Sel->getCondition())) {
      Value *ca = Cmp->getOperand(0), *cb = Cmp->getOperand(1);
      Value *tv = Sel->getTrueValue(), *fv = Sel->getFalseValue();
      P = Cmp->getPredicate();
      bool minmaxA = (ca == tv && cb == fv), minmaxB = (ca == fv && cb == tv);
      if (minmaxA || minmaxB) {
        const char *op = nullptr;
        bool lt = (P == ICmpInst::ICMP_SLT || P == ICmpInst::ICMP_SLE);
        bool gt = (P == ICmpInst::ICMP_SGT || P == ICmpInst::ICMP_SGE);
        if (lt) op = minmaxA ? "min" : "max";
        else if (gt) op = minmaxA ? "max" : "min";
        if (op) {
          std::string sa, sb;
          if (!emitNode(ca, L, IV, Acc, SM, argNo, sa, depth + 1)) return false;
          if (!emitNode(cb, L, IV, Acc, SM, argNo, sb, depth + 1)) return false;
          out += "{\"op\":" + jstr(op) + ",\"a\":" + sa + ",\"b\":" + sb + "}";
          return true;
        }
      }
    }
    return false;
  }

  if (auto *BO = dyn_cast<BinaryOperator>(V)) {
    const char *op = nullptr;
    switch (BO->getOpcode()) {
      case Instruction::Add: op = "add"; break;
      case Instruction::Sub: op = "sub"; break;
      case Instruction::Mul: op = "mul"; break;
      case Instruction::And: op = "and"; break;
      case Instruction::Or:  op = "or";  break;
      case Instruction::Xor: op = "xor"; break;
      case Instruction::Shl: op = "shl"; break;
      default: return false;
    }
    std::string sa, sb;
    if (!emitNode(BO->getOperand(0), L, IV, Acc, SM, argNo, sa, depth + 1)) return false;
    if (!emitNode(BO->getOperand(1), L, IV, Acc, SM, argNo, sb, depth + 1)) return false;
    out += "{\"op\":" + jstr(op) + ",\"a\":" + sa + ",\"b\":" + sb + "}";
    return true;
  }
  return false;
}

static bool hasTaluAnnotation(Module &M, Function &F) {
  auto *GA = M.getGlobalVariable("llvm.global.annotations");
  if (!GA || !GA->hasInitializer()) return false;
  auto *arr = dyn_cast<ConstantArray>(GA->getInitializer());
  if (!arr) return false;
  for (auto &op : arr->operands()) {
    auto *st = dyn_cast<ConstantStruct>(op);
    if (!st) continue;
    auto *fn = dyn_cast<Function>(st->getOperand(0)->stripPointerCasts());
    if (fn != &F) continue;
    auto *gv = dyn_cast<GlobalVariable>(st->getOperand(1)->stripPointerCasts());
    if (!gv || !gv->hasInitializer()) continue;
    if (auto *cda = dyn_cast<ConstantDataArray>(gv->getInitializer()))
      if (cda->isCString() && cda->getAsCString() == "talu") return true;
  }
  return false;
}

struct TALUMapPass : PassInfoMixin<TALUMapPass> {
  PreservedAnalyses run(Module &M, ModuleAnalysisManager &MAM) {
    auto &FAM = MAM.getResult<FunctionAnalysisManagerModuleProxy>(M).getManager();
    std::error_code EC;
    std::string outfile = (M.getName() + ".talu.json").str();
    if (getenv("TALU_JSON")) outfile = getenv("TALU_JSON");
    raw_fd_ostream J(outfile, EC, sys::fs::OF_Text);
    J << "{\"kernels\":[\n";
    bool first = true;

    for (Function &F : M) {
      if (F.isDeclaration() || !hasTaluAnnotation(M, F)) continue;
      LoopInfo &LI = FAM.getResult<LoopAnalysis>(F);
      if (LI.getLoopsInPreorder().empty()) { errs() << "talu: no loop in " << F.getName() << "\n"; continue; }
      Loop *L = LI.getLoopsInPreorder().back();          // innermost

      // classify streams: pointer args are streams; find the induction phi and
      // an optional accumulator phi in the loop header.
      std::map<const Value *, int> argNo;
      int nptr = 0;
      for (Argument &A : F.args())
        if (A.getType()->isPointerTy()) argNo[&A] = nptr++;

      PHINode *IV = nullptr, *Acc = nullptr;
      BasicBlock *H = L->getHeader();
      for (PHINode &phi : H->phis()) {
        if (phi.getType()->isIntegerTy(64)) IV = &phi;      // loop counter
        else if (phi.getType()->isIntegerTy(32)) Acc = &phi; // reduction acc
      }
      if (!IV) { errs() << "talu: no i64 IV in " << F.getName() << "\n"; continue; }

      StreamMap SM;
      std::string pattern, expr, dstJson = "null", retType = "void";
      int dstArg = -1;

      if (Acc) {
        // reduction: acc = add(compute, acc). Find the add feeding acc's latch.
        pattern = "reduce";
        Value *inc = Acc->getIncomingValueForBlock(L->getLoopLatch());
        auto *add = dyn_cast<BinaryOperator>(inc);
        if (!add || add->getOpcode() != Instruction::Add) { errs() << "talu: acc not add in " << F.getName() << "\n"; continue; }
        Value *comp = (add->getOperand(0) == Acc) ? add->getOperand(1) : add->getOperand(0);
        if (!emitNode(comp, L, IV, /*Acc*/nullptr, SM, argNo, expr, 0)) {
          errs() << "talu: unmapped reduce DAG in " << F.getName() << "\n"; continue;
        }
        retType = "i32";
      } else {
        // map: single store in the loop body of a compute over streams.
        StoreInst *ST = nullptr;
        for (BasicBlock *BB : L->blocks())
          for (Instruction &I : *BB)
            if (auto *s = dyn_cast<StoreInst>(&I)) ST = s;
        if (!ST) { errs() << "talu: no store in map " << F.getName() << "\n"; continue; }
        pattern = "map";
        auto *GEP = dyn_cast<GetElementPtrInst>(ST->getPointerOperand());
        if (GEP && argNo.count(GEP->getPointerOperand()))
          dstArg = argNo[GEP->getPointerOperand()];
        if (!emitNode(ST->getValueOperand(), L, IV, nullptr, SM, argNo, expr, 0)) {
          errs() << "talu: unmapped map DAG in " << F.getName() << "\n"; continue;
        }
        dstJson = std::to_string(dstArg);
      }

      if (!first) J << ",\n";
      first = false;
      J << "  {\"name\":" << jstr(F.getName())
        << ",\"pattern\":" << jstr(pattern)
        << ",\"nargs_ptr\":" << nptr
        << ",\"dst_arg\":" << dstJson
        << ",\"ret\":" << jstr(retType)
        << ",\"expr\":" << expr << "}";
      errs() << "talu: mapped " << F.getName() << " (" << pattern << ")\n";
    }
    J << "\n]}\n";
    return PreservedAnalyses::all();
  }
  static bool isRequired() { return true; }
};

} // namespace

llvm::PassPluginLibraryInfo getTALUPluginInfo() {
  return {LLVM_PLUGIN_API_VERSION, "TALUMap", "0.1", [](PassBuilder &PB) {
    PB.registerPipelineParsingCallback(
        [](StringRef Name, ModulePassManager &MPM,
           ArrayRef<PassBuilder::PipelineElement>) {
          if (Name == "talu-map") { MPM.addPass(TALUMapPass()); return true; }
          return false;
        });
  }};
}
extern "C" LLVM_ATTRIBUTE_WEAK ::llvm::PassPluginLibraryInfo llvmGetPassPluginInfo() {
  return getTALUPluginInfo();
}
