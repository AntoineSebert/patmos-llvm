; RUN: llvm-as %s -o /dev/null
; RUN: verify-uselistorder %s -preserve-bc-use-list-order
; Test that shift instructions can be used in constant expressions.

global i32 3670016
