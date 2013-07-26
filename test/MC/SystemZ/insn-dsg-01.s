# RUN: llvm-mc -triple s390x-linux-gnu -show-encoding %s | FileCheck %s

#CHECK: dsg	%r0, -524288            # encoding: [0xe3,0x00,0x00,0x00,0x80,0x0d]
#CHECK: dsg	%r0, -1                 # encoding: [0xe3,0x00,0x0f,0xff,0xff,0x0d]
#CHECK: dsg	%r0, 0                  # encoding: [0xe3,0x00,0x00,0x00,0x00,0x0d]
#CHECK: dsg	%r0, 1                  # encoding: [0xe3,0x00,0x00,0x01,0x00,0x0d]
#CHECK: dsg	%r0, 524287             # encoding: [0xe3,0x00,0x0f,0xff,0x7f,0x0d]
#CHECK: dsg	%r0, 0(%r1)             # encoding: [0xe3,0x00,0x10,0x00,0x00,0x0d]
#CHECK: dsg	%r0, 0(%r15)            # encoding: [0xe3,0x00,0xf0,0x00,0x00,0x0d]
#CHECK: dsg	%r0, 524287(%r1,%r15)   # encoding: [0xe3,0x01,0xff,0xff,0x7f,0x0d]
#CHECK: dsg	%r0, 524287(%r15,%r1)   # encoding: [0xe3,0x0f,0x1f,0xff,0x7f,0x0d]
#CHECK: dsg	%r14, 0                 # encoding: [0xe3,0xe0,0x00,0x00,0x00,0x0d]

	dsg	%r0, -524288
	dsg	%r0, -1
	dsg	%r0, 0
	dsg	%r0, 1
	dsg	%r0, 524287
	dsg	%r0, 0(%r1)
	dsg	%r0, 0(%r15)
	dsg	%r0, 524287(%r1,%r15)
	dsg	%r0, 524287(%r15,%r1)
	dsg	%r14, 0
