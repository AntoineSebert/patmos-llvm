; Test 64-bit equality comparisons in which the second operand is a constant.
;
; RUN: llc < %s -mtriple=s390x-linux-gnu | FileCheck %s

; Check comparisons with 0.
define double @f1(double %a, double %b, i64 %i1) {
; CHECK: f1:
; CHECK: cghi %r2, 0
; CHECK-NEXT: j{{g?}}e
; CHECK: ldr %f0, %f2
; CHECK: br %r14
  %cond = icmp eq i64 %i1, 0
  %res = select i1 %cond, double %a, double %b
  ret double %res
}

; Check the high end of the CGHI range.
define double @f2(double %a, double %b, i64 %i1) {
; CHECK: f2:
; CHECK: cghi %r2, 32767
; CHECK-NEXT: j{{g?}}e
; CHECK: ldr %f0, %f2
; CHECK: br %r14
  %cond = icmp eq i64 %i1, 32767
  %res = select i1 %cond, double %a, double %b
  ret double %res
}

; Check the next value up, which must use CGFI.
define double @f3(double %a, double %b, i64 %i1) {
; CHECK: f3:
; CHECK: cgfi %r2, 32768
; CHECK-NEXT: j{{g?}}e
; CHECK: ldr %f0, %f2
; CHECK: br %r14
  %cond = icmp eq i64 %i1, 32768
  %res = select i1 %cond, double %a, double %b
  ret double %res
}

; Check the high end of the CGFI range.
define double @f4(double %a, double %b, i64 %i1) {
; CHECK: f4:
; CHECK: cgfi %r2, 2147483647
; CHECK-NEXT: j{{g?}}e
; CHECK: ldr %f0, %f2
; CHECK: br %r14
  %cond = icmp eq i64 %i1, 2147483647
  %res = select i1 %cond, double %a, double %b
  ret double %res
}

; Check the next value up, which should use CLGFI instead.
define double @f5(double %a, double %b, i64 %i1) {
; CHECK: f5:
; CHECK: clgfi %r2, 2147483648
; CHECK-NEXT: j{{g?}}e
; CHECK: ldr %f0, %f2
; CHECK: br %r14
  %cond = icmp eq i64 %i1, 2147483648
  %res = select i1 %cond, double %a, double %b
  ret double %res
}

; Check the high end of the CLGFI range.
define double @f6(double %a, double %b, i64 %i1) {
; CHECK: f6:
; CHECK: clgfi %r2, 4294967295
; CHECK-NEXT: j{{g?}}e
; CHECK: ldr %f0, %f2
; CHECK: br %r14
  %cond = icmp eq i64 %i1, 4294967295
  %res = select i1 %cond, double %a, double %b
  ret double %res
}

; Check the next value up, which must use a register comparison.
define double @f7(double %a, double %b, i64 %i1) {
; CHECK: f7:
; CHECK: cgr %r2,
; CHECK-NEXT: j{{g?}}e
; CHECK: ldr %f0, %f2
; CHECK: br %r14
  %cond = icmp eq i64 %i1, 4294967296
  %res = select i1 %cond, double %a, double %b
  ret double %res
}

; Check the high end of the negative CGHI range.
define double @f8(double %a, double %b, i64 %i1) {
; CHECK: f8:
; CHECK: cghi %r2, -1
; CHECK-NEXT: j{{g?}}e
; CHECK: ldr %f0, %f2
; CHECK: br %r14
  %cond = icmp eq i64 %i1, -1
  %res = select i1 %cond, double %a, double %b
  ret double %res
}

; Check the low end of the CGHI range.
define double @f9(double %a, double %b, i64 %i1) {
; CHECK: f9:
; CHECK: cghi %r2, -32768
; CHECK-NEXT: j{{g?}}e
; CHECK: ldr %f0, %f2
; CHECK: br %r14
  %cond = icmp eq i64 %i1, -32768
  %res = select i1 %cond, double %a, double %b
  ret double %res
}

; Check the next value down, which must use CGFI instead.
define double @f10(double %a, double %b, i64 %i1) {
; CHECK: f10:
; CHECK: cgfi %r2, -32769
; CHECK-NEXT: j{{g?}}e
; CHECK: ldr %f0, %f2
; CHECK: br %r14
  %cond = icmp eq i64 %i1, -32769
  %res = select i1 %cond, double %a, double %b
  ret double %res
}

; Check the low end of the CGFI range.
define double @f11(double %a, double %b, i64 %i1) {
; CHECK: f11:
; CHECK: cgfi %r2, -2147483648
; CHECK-NEXT: j{{g?}}e
; CHECK: ldr %f0, %f2
; CHECK: br %r14
  %cond = icmp eq i64 %i1, -2147483648
  %res = select i1 %cond, double %a, double %b
  ret double %res
}

; Check the next value down, which must use register comparison.
define double @f12(double %a, double %b, i64 %i1) {
; CHECK: f12:
; CHECK: cgr
; CHECK-NEXT: j{{g?}}e
; CHECK: ldr %f0, %f2
; CHECK: br %r14
  %cond = icmp eq i64 %i1, -2147483649
  %res = select i1 %cond, double %a, double %b
  ret double %res
}
