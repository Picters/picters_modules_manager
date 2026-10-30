#!/usr/bin/env python3
"""Recover the captured Xiaomi thermal-policy key offline, without running a daemon.

Requires Unicorn (ARM64 emulation). Only the pinned loader's pure white-box
block-decryption routine is emulated, with no OS, syscalls or external libraries.
This is a thermal file-format key, not a device signing or authentication key.
"""
import argparse
import hashlib
from pathlib import Path

LOADER_SHA256 = 'df25b03dfb7081c6b85e130a457f48b049c0f2056979ee407208d5fdf86b057e'
BLOCK_ROUTINE = 0xC8BC8
WRAPPED_KEY_OFFSET = 0xD455A


def recover(loader):
    from unicorn import Uc, UC_ARCH_ARM64, UC_MODE_ARM, UC_HOOK_INTR
    from unicorn.arm64_const import UC_ARM64_REG_X0, UC_ARM64_REG_SP, UC_ARM64_REG_LR, UC_ARM64_REG_PC

    binary = loader.read_bytes()
    if hashlib.sha256(binary).hexdigest() != LOADER_SHA256:
        raise ValueError('Unknown loader version: offsets and cipher have not been verified.')
    wrapped = bytes.fromhex(binary[WRAPPED_KEY_OFFSET:WRAPPED_KEY_OFFSET + 64].decode('ascii'))
    vm = Uc(UC_ARCH_ARM64, UC_MODE_ARM)
    vm.mem_map(0, 0x100000)
    vm.mem_write(0, binary)
    vm.mem_map(0x200000, 0x10000)
    vm.mem_map(0x300000, 0x1000)
    vm.mem_map(0x400000, 0x1000)

    def reject_interrupt(*args):
        raise RuntimeError('Unexpected interrupt in the pure cipher routine')

    vm.hook_add(UC_HOOK_INTR, reject_interrupt)
    previous = bytes(16)
    plain = bytearray()
    for offset in range(0, len(wrapped), 16):
        block = wrapped[offset:offset + 16]
        vm.mem_write(0x300000, block)
        vm.reg_write(UC_ARM64_REG_SP, 0x20FFF0)
        vm.reg_write(UC_ARM64_REG_LR, 0x400000)
        vm.reg_write(UC_ARM64_REG_X0, 0x300000)
        vm.emu_start(BLOCK_ROUTINE, 0x400000, timeout=5_000_000, count=1_000_000)
        if vm.reg_read(UC_ARM64_REG_PC) != 0x400000:
            raise RuntimeError('Cipher routine did not return within its limit')
        decoded = bytes(vm.mem_read(0x300000, 16))
        plain.extend(a ^ b for a, b in zip(decoded, previous))
        previous = block
    if len(plain) != 32 or plain[16:] != bytes([16]) * 16:
        raise ValueError('Wrapped key padding does not validate')
    return bytes(plain[:16])


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('loader', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    key = recover(args.loader)
    with args.output.open('xb') as output:
        output.write(key)
    print('Recovered 16-byte thermal policy key; wrapped-key padding verified.')
