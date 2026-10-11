# TALU LLVM mapping pass (out-of-tree, new PM plugin)
LLVM_CONFIG ?= /usr/lib/llvm-20/bin/llvm-config
CXX         ?= clang++
CXXFLAGS    := $(shell $(LLVM_CONFIG) --cxxflags) -fPIC -Wall

all: TALUMap.so

TALUMap.so: TALUMap.cpp
	$(CXX) $(CXXFLAGS) -shared -o $@ $<

test: TALUMap.so
	python3 verify.py

clean:
	rm -f TALUMap.so build/*
.PHONY: all test clean
