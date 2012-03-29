//===- FlowFactProvider - Flowfacts provider for IPET analysis -------------===//
//
//                     The LLVM Compiler Infrastructure
//
// This file is distributed under the University of Illinois Open Source
// License. See LICENSE.TXT for details.
//
//===----------------------------------------------------------------------===//
//
// Simple flowfact provider interface and implementation.
//
//===----------------------------------------------------------------------===//

#ifndef _LLVM_IPET_FLOWFACTPROVIDER_H_
#define _LLVM_IPET_FLOWFACTPROVIDER_H_

#define DEBUG_TYPE "ipet"

#include "llvm/Pass.h"
#include "llvm/BasicBlock.h"
#include "llvm/Support/raw_ostream.h"
#include "llvm/Support/InstVisitor.h"
#include "llvm/ADT/StringMap.h"
#include "llvm/ADT/Statistic.h"
#include "llvm/ADT/SmallVector.h"


using namespace llvm;

namespace ipet {

  class FlowFactProvider {
    public:
      enum ConstraintType { CT_LE, CT_EQ, CT_GE };

      typedef std::pair<BasicBlock*,BasicBlock*> Edge;
      typedef std::vector<Edge> EdgeList;

      /**
       * Constraint of form: ef_Block <Cmp> N * ef_Ref.
       *
       * If Ref is NULL, then it is of the form ef_Block <Cmp> N.
       *
       * TODO maybe support a set of blocks instead of Block?
       */
      struct BlockConstraint {
          BlockConstraint(const BasicBlock *Block, const BasicBlock *Ref, ConstraintType Cmp, int N) :
            Block(Block), Ref(Ref), Cmp(Cmp), N(N) {}

          const BasicBlock *Block;
          const BasicBlock *Ref;
          ConstraintType    Cmp;
          int               N;
      };

      /**
       * Constraint of form: sum( ef_edges ) <Cmp> N * sum( ingoing edges of Ref \ edges )
       *
       * If Ref is NULL, then it is of the form: sum( ef_edges ) <Cmp> N.
       * A loop bound can be expressed as edges := backedges, Ref := loop-header, N := loop-bound, Cmp := LE.
       */
      struct EdgeConstraint {
          EdgeConstraint(EdgeList Edges, const BasicBlock *Ref, ConstraintType Cmp, int N) :
            Edges(Edges), Ref(Ref), Cmp(Cmp), N(N) {}

          EdgeList          Edges;
          const BasicBlock *Ref;
          ConstraintType    Cmp;
          int               N;
      };

      typedef std::vector<BlockConstraint> BlockConstraints;
      typedef std::vector<EdgeConstraint>  EdgeConstraints;

      virtual ~FlowFactProvider() {}

      /**
       * Resets all constraints to the initial constraints (loop bounds from analyses,..).
       */
      virtual void reset() { bcList.clear(); ecList.clear(); }

      size_t addBlockConstraint(const BasicBlock *block, int N, ConstraintType cmp = CT_LE,
          const BasicBlock *Ref = NULL);

      size_t addEdgeConstraint(const BasicBlock *source, const BasicBlock *target, int N, ConstraintType cmp = CT_LE,
          const BasicBlock *Ref = NULL);

      const BlockConstraints &getBlockConstraints() const { return bcList; }
      const EdgeConstraints  &getEdgeConstraints() const  { return ecList; }

    protected:
      BlockConstraints  bcList;
      EdgeConstraints   ecList;
  };

  class SCEVFlowFactProvider : public FlowFactProvider {
    public:
      SCEVFlowFactProvider();
      virtual ~SCEVFlowFactProvider() {}

      virtual void reset();

    private:
      void loadLoopBounds();

  };

}

#endif // _LLVM_IPET_FLOWFACTPROVIDER_H_
