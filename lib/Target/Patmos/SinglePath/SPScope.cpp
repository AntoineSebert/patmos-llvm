//==-- SPScope.cpp -  -------------------===//
//
//                     The LLVM Compiler Infrastructure
//
// This file is distributed under the University of Illinois Open Source
// License. See LICENSE.TXT for details.
//
//===---------------------------------------------------------------------===//
//
//
//
//===---------------------------------------------------------------------===//
#define DEBUG_TYPE "patmos-singlepath"

#include "SPScope.h"
#include "Patmos.h"
#include "llvm/ADT/PostOrderIterator.h"

using namespace llvm;

SPScope::SPScope(MachineBasicBlock *header, bool isRootTopLevel)
                    : Parent(NULL), FCFG(header),
                      RootTopLevel(isRootTopLevel), LoopBound(-1) {
  Depth = 0;
  // add header also to this SPScope's block list
  Blocks.push_back(header);

}

SPScope::SPScope(SPScope *parent, MachineLoop &loop)
  : Parent(parent), FCFG(loop.getHeader()),
    RootTopLevel(false), LoopBound(-1) {

  assert(parent);
  MachineBasicBlock *header = loop.getHeader();

  // add to parent's child list
  Parent->HeaderMap[header] = this;
  Parent->Subscopes.push_back(this);
  // add to parent's block list as well
  Parent->addMBB(header);
  Depth = Parent->Depth + 1;

  // add header also to this SPScope's block list
  Blocks.push_back(header);

  // info about loop latches and exit edges
  loop.getLoopLatches(Latches);
  loop.getExitEdges(ExitEdges);

  // scan the header for loopbound info
  for (MachineBasicBlock::iterator MI = header->begin(), ME = header->end();
      MI != ME; ++MI) {
    if (MI->getOpcode() == Patmos::PSEUDO_LOOPBOUND) {
      // max is the second operand (idx 1)
      LoopBound = MI->getOperand(1).getImm() + 1;
      break;
    }
  }

}

/// destructor - free the child scopes first, cleanup
SPScope::~SPScope() {
  for (unsigned i=0; i<Subscopes.size(); i++) {
    delete Subscopes[i];
  }
  Subscopes.clear();
  HeaderMap.clear();
}

void SPScope::addMBB(MachineBasicBlock *MBB) {
  if (Blocks.front() != MBB) {
    Blocks.push_back(MBB);
  }
}

SPScope::Edge SPScope::getDual(Edge &e) const {
  const MachineBasicBlock *src = e.first;
  assert(src->succ_size() == 2);
  for (MachineBasicBlock::const_succ_iterator si = src->succ_begin(),
      se = src->succ_end(); si != se; ++si) {
    if (*si != e.second) {
      return std::make_pair(src, *si);
    }
  }
  llvm_unreachable("no dual edge found");
  return std::make_pair((const MachineBasicBlock *) NULL,
                        (const MachineBasicBlock *) NULL);
}

bool SPScope::isHeader(const MachineBasicBlock *MBB) const {
  return getHeader() == MBB;
}

bool SPScope::isMember(const MachineBasicBlock *MBB) const {
  for (unsigned i=0; i<Blocks.size(); i++) {
    if (Blocks[i] == MBB) return true;
  }
  return false;
}

bool SPScope::isSubHeader(MachineBasicBlock *MBB) const {
  return HeaderMap.count(MBB) > 0;
}

const std::vector<const MachineBasicBlock *> SPScope::getSuccMBBs() const {
  std::vector<const MachineBasicBlock *> SuccMBBs;
  for (unsigned i=0; i<ExitEdges.size(); i++) {
    SuccMBBs.push_back(ExitEdges[i].second);
  }
  return SuccMBBs;
}

void SPScope::computePredInfos(void) {

  buildfcfg();
  toposort();
  FCFG.postdominators();
  DEBUG_TRACE(dumpfcfg()); // uses info about pdom
  ctrldep();
  decompose();
}

void SPScope::buildfcfg(void) {
  std::set<const MachineBasicBlock *> body(++Blocks.begin(), Blocks.end());
  std::vector<Edge> outedges;

  for (unsigned i=0; i<Blocks.size(); i++) {
    MachineBasicBlock *MBB = Blocks[i];

    if (HeaderMap.count(MBB)) {
      const SPScope *subloop = HeaderMap[MBB];
      // successors of the loop
      outedges.insert(outedges.end(),
                      subloop->ExitEdges.begin(),
                      subloop->ExitEdges.end());
    } else {
      // simple block
      for (MachineBasicBlock::succ_iterator si = MBB->succ_begin(),
            se = MBB->succ_end(); si != se; ++si) {
        outedges.push_back(std::make_pair(MBB, *si));
      }
    }

    Node &n = FCFG.getNodeFor(MBB);
    for (unsigned i=0; i<outedges.size(); i++) {
      const MachineBasicBlock *succ = outedges[i].second;
      if (body.count(succ)) {
        Node &ns = FCFG.getNodeFor(succ);
        n.connect(ns, outedges[i]);
      } else {
        if (succ != getHeader()) {
          // record exit edges
          FCFG.toexit(n, outedges[i]);
        } else {
          // we don't need back edges recorded
          FCFG.toexit(n);
        }
      }
    }

    // special case: top-level loop has no exit/backedge
    if (outedges.empty()) {
      assert(isTopLevel());
      FCFG.toexit(n);
    }
    outedges.clear();
  }
}

void SPScope::toposort(void) {
  // dfs the FCFG in postorder
  std::vector<MachineBasicBlock *> PO;
  for (po_iterator<SPScope*> I = po_begin(this), E = po_end(this);
      I != E; ++I) {
    MachineBasicBlock *MBB = const_cast<MachineBasicBlock*>((*I)->MBB);
    if (MBB) PO.push_back(MBB);
  }
  // clear the blocks vector and re-insert MBBs in reverse post order
  Blocks.clear();
  Blocks.insert(Blocks.end(), PO.rbegin(), PO.rend());
}

void SPScope::FCFG::_rdfs(Node *n, std::set<Node*> &V,
    std::vector<Node*> &order) {
  V.insert(n);
  n->num = -1;
  for (Node::child_iterator I = n->preds_begin(), E = n->preds_end();
      I != E; ++I) {
    if (!V.count(*I)) {
      _rdfs(*I, V, order);
    }
  }
  n->num = order.size();
  order.push_back(n);
}

SPScope::Node *SPScope::FCFG::_intersect(Node *b1, Node *b2) {
  assert(b2 != NULL);
  if (b2->ipdom == NULL) {
    return b1;
  }
  Node *finger1 = (b1 != NULL) ? b1 : b2;
  Node *finger2 = b2;
  while (finger1->num != finger2->num) {
    while (finger1->num < finger2->num) finger1 = finger1->ipdom;
    while (finger2->num < finger1->num) finger2 = finger2->ipdom;
  }
  return finger1;
}

void SPScope::FCFG::postdominators(void) {
  // adopted from:
  //   Cooper K.D., Harvey T.J. & Kennedy K. (2001).
  //   A simple, fast dominance algorithm
  // As we compute _post_dominators, we generate a PO numbering of the
  // reversed graph and consider the successors instead of the predecessors.

  // first, we generate a postorder numbering
  std::set<Node*> visited;
  std::vector<Node*> order;
  // as we construct the postdominators, we dfs the reverse graph
  _rdfs(&nexit, visited, order);

  // initialize "start" (= exit) node
  nexit.ipdom = &nexit;

  // for all nodes except start node in reverse postorder
  for (std::vector<Node *>::reverse_iterator i = ++order.rbegin(),
      e = order.rend(); i != e; ++i) {
    Node *n = *i;
    // one pass is enough for acyclic graph, no loop required
    Node *new_ipdom = NULL;
    for (Node::child_iterator si = n->succs_begin(), se = n->succs_end();
        si != se; ++si) {
      new_ipdom = _intersect(new_ipdom, *si);
    }
    // assign the intersection
    n->ipdom = new_ipdom;
  }
}

void SPScope::_walkpdt(Node *a, Node *b, Edge &e) {
  _walkpdt(a, b, e, a);
}

void SPScope::_walkpdt(Node *a, Node *b, Edge &e, Node *edgesrc) {
  Node *t = b;
  while (t != a->ipdom) {
    // add edge e to control dependence of t
    CD[t->MBB].insert(std::make_pair(edgesrc, e));
    t = t->ipdom;
  }
}

void SPScope::ctrldep(void) {

  for (df_iterator<SPScope*> I = df_begin(this), E = df_end(this);
      I != E; ++I) {
    Node *n = *I;
    if (n->dout() >= 2) {
      for (Node::child_iterator it = n->succs_begin(), et = n->succs_end();
            it != et; ++it) {
        Edge *e = n->edgeto(*it);
        if (e) _walkpdt(n, *it, *e);
      }
    }
  }
  // find exit edges
  for (Node::child_iterator it = FCFG.nexit.preds_begin(),
        et = FCFG.nexit.preds_end(); it != et; ++it) {
    Edge *e = (*it)->edgeto(&FCFG.nexit);
    if (!e) continue;
    // we found an exit edge
    Edge dual = getDual(*e);
    _walkpdt(&FCFG.nentry, &FCFG.getNodeFor(getHeader()), dual, *it);
  }

  DEBUG_TRACE({
    // dump CD
    dbgs() << "Control dependence:\n";
    for (CD_map_t::iterator I=CD.begin(), E=CD.end(); I!=E; ++I) {
      dbgs().indent(4) << "BB#" << I->first->getNumber() << ": { ";
      for (CD_map_entry_t::iterator EI=I->second.begin(), EE=I->second.end();
           EI!=EE; ++EI) {
        Node *n = EI->first;
        Edge e  = EI->second;
        FCFG.printNode(*n) << "(" << ((e.first) ? e.first->getNumber() : -1) << ","
                      << e.second->getNumber() << "), ";
      }
      dbgs() << "}\n";
    }
  });
}

void SPScope::decompose(void) {
  MBBPredicates_t mbbPreds;
  std::vector<CD_map_entry_t> K;
  int p = 0;
  for (unsigned i=0; i<Blocks.size(); i++) {
    const MachineBasicBlock *MBB = Blocks[i];
    CD_map_entry_t t = CD.at(MBB);
    int q=-1;
    // try to lookup the control dependence
    for (unsigned int i=0; i<K.size(); i++) {
        if ( t == K[i] ) {
          q = i;
          break;
        }
    }
    assert(mbbPreds.find(MBB) ==  mbbPreds.end());
    mbbPreds.insert(std::make_pair(MBB, std::vector<unsigned>()));
    if (q != -1) {
      // we already have handled this dependence
      mbbPreds[MBB].push_back(q);
    } else {
      // new dependence set:
      K.push_back(t);
      mbbPreds[MBB].push_back(p++);
    }
  } // end for each MBB

  DEBUG_TRACE({
    // dump R, K
    dbgs() << "Decomposed CD:\n";
    dbgs().indent(2) << "map R: MBB -> pN\n";
    for (MBBPredicates_t::iterator RI = mbbPreds.begin(), RE = mbbPreds.end(); RI != RE; ++RI) {
      dbgs().indent(4) << "R(" << RI->first->getNumber() << ") ={";
      std::for_each(RI->second.begin(), RI->second.end(), [](unsigned n){ dbgs() << n << ", ";});
      dbgs() << "}\n";
    }
    dbgs().indent(2) << "map K: pN -> t \\in CD\n";
    for (unsigned long i = 0; i < K.size(); i++) {
      dbgs().indent(4) << "K(p" << i << ") -> {";
      for (CD_map_entry_t::iterator EI=K[i].begin(), EE=K[i].end();
            EI!=EE; ++EI) {
        Node *n = EI->first;
        Edge e  = EI->second;
        FCFG.printNode(*n) << "(" << ((e.first) ? e.first->getNumber() : -1)
                           << "," << e.second->getNumber() << "), ";
      }
      dbgs() << "}\n";
    }
  });



  // Properly assign the Uses/Defs
  PredCount = K.size();
  PredUse = mbbPreds;
  // initialize number of defining edges to 0 for all predicates
  NumPredDefEdges = std::vector<unsigned>( K.size(), 0 );

  // For each predicate, compute defs
  for (unsigned int i=0; i<K.size(); i++) {
    // store number of defining edges
    NumPredDefEdges[i] = K[i].size();
    // for each definition edge
    for (CD_map_entry_t::iterator EI=K[i].begin(), EE=K[i].end();
              EI!=EE; ++EI) {
      Node *n = EI->first;
      Edge e  = EI->second;
      if (n == &FCFG.nentry) {
        // Pseudo edge (from start node)
        //assert(e.first == NULL);
        assert(e.second == getHeader());
        continue;
      }

      // get pred definition info of node
      PredDefInfo &PredDef = getOrCreateDefInfo(n->MBB);
      // insert definition edge for predicate i
      PredDef.define(i, e);
    } // end for each definition edge
  }
}

raw_ostream& SPScope::FCFG::printNode(Node &n) {
  raw_ostream& os = dbgs();
  if (&n == &nentry) {
    os << "_S<" << n.num << ">";
  } else if (&n == &nexit) {
    os << "_T<" << n.num << ">";
  } else {
    os << "BB#" << n.MBB->getNumber() << "<" << n.num << ">";
  }
  return os;
}

void SPScope::dumpfcfg(void) {
  dbgs() << "==========\nFCFG [BB#" << getHeader()->getNumber() << "]\n";

  for (df_iterator<SPScope*> I = df_begin(this), E = df_end(this);
      I != E; ++I) {

    dbgs().indent(2);
    FCFG.printNode(**I) << " ipdom ";
    FCFG.printNode(*(*I)->ipdom) << " -> {";
    // print outgoing edges
    for (Node::child_iterator SI = (*I)->succs_begin(), SE = (*I)->succs_end();
          SI != SE; ++SI ) {
      FCFG.printNode(**SI) << ", ";
    }
    dbgs() << "}\n";
  }
}

void SPScope::walk(SPScopeWalker &walker) {
  walker.enterSubscope(this);
  for (unsigned i=0; i<Blocks.size(); i++) {
    MachineBasicBlock *MBB = Blocks[i];
    if (HeaderMap.count(MBB)) {
      HeaderMap[MBB]->walk(walker);
    } else {
      walker.nextMBB(MBB);
    }
  }
  walker.exitSubscope(this);
}

static void printUDInfo(const SPScope &S, raw_ostream& os,
                        const MachineBasicBlock *MBB) {
  os << "  u={";
  const std::vector<unsigned> *preds = S.getPredUse(MBB);
  std::for_each(preds->begin(), preds->end(), [&](unsigned p){os << p << ", ";});
  os << "}";
  const SPScope::PredDefInfo *DI = S.getDefInfo(MBB);
  if (DI) {
    os << " d=";
    for (SPScope::PredDefInfo::iterator pi = DI->begin(), pe = DI->end();
        pi != pe; ++pi) {
      os << pi->first << ",";
    }
  }
  os << "\n";
}

void SPScope::dump(raw_ostream& os) const {
  os.indent(2*Depth) <<  "[BB#" << Blocks.front()->getNumber() << "]";
  if (!Parent) {
    os << " (top)";
    assert(ExitEdges.empty());
    assert(Latches.empty());
  }
  if (!ExitEdges.empty()) {
    os << " -> { ";
    for (unsigned i=0; i<ExitEdges.size(); i++) {
      os << "BB#" << ExitEdges[i].second->getNumber() << " ";
    }
    os << "}";
  }
  if (!Latches.empty()) {
    os << " L { ";
    for (unsigned i=0; i<Latches.size(); i++) {
      os << "BB#" << Latches[i]->getNumber() << " ";
    }
    os << "}";
  }
  os << " |P|=" <<  PredCount;
  printUDInfo(*this, os, Blocks.front());

  for (unsigned i=1; i<Blocks.size(); i++) {
    MachineBasicBlock *MBB = Blocks[i];
    os.indent(2*(Depth+1)) << " BB#" << MBB->getNumber();
    printUDInfo(*this, os, MBB);
    if (HeaderMap.count(MBB)) {
      HeaderMap.at(MBB)->dump(os);
    }
  }
}

const std::vector<unsigned> *SPScope::getPredUse(const MachineBasicBlock *MBB) const {
  if (PredUse.count(MBB)) {
    return &PredUse.at(MBB);
  }
  return NULL;
}

const SPScope::PredDefInfo *
SPScope::getDefInfo( const MachineBasicBlock *MBB) const {

  if (PredDefs.count(MBB)) {
    return &PredDefs.at(MBB);
  }
  return NULL;
}

SPScope::PredDefInfo &
SPScope::getOrCreateDefInfo(const MachineBasicBlock *MBB) {

  if (!PredDefs.count(MBB)) {
    // Create new info
    PredDefs.insert(std::make_pair(MBB, PredDefInfo()));
  }

  return PredDefs.at(MBB);
}




