# NixOS OpenCL development flake

This flake contains a dev shell with a bunch of OpenCL drivers and tooling. It contains some stuff that is not found in nixpkgs and attempts to provide more recent versions of the things that are. Currently, the following things are packaged:

- A slim debug build of the master branch of [mesa](https://gitlab.freedesktop.org/mesa/mesa/). Only the swrast, radeonsi and nouveau gallium drivers are enabled and none of the Vulkan ones. RustiCL is also enabled. Note that the RustiCL backend is set to `swrast:0` by default, set the `RUSTICL_ENABLE` environment variable to override that.
- The [Intel OpenCL CPU Runtime](https://www.intel.com/content/www/us/en/developer/articles/tool/opencl-drivers.html), version WW2023-46. This driver is based off LLVM 17 and LLVM-SPIRV-Translator 17, so it misses a bunch of goodies.
- A build of the master branch of [POCL](https://github.com/pocl/pocl).
- [shady](https://github.com/shady-gang/shady)
- [spirv2clc](https://github.com/kpet/spirv2clc)

A single environment is constructed that brings all of these drivers together, including some that are already packaged in nixpkgs. The [Khronos OpenCL ICD Loader](https://github.com/KhronosGroup/OpenCL-ICD-Loader) is used as ICD loader to switch between drivers.

## Usage

To use this dev shell from another flake, first import it as usual and then use `inputsFrom = [ nixos-opencl.devShells.${system}.default ];` in your `mkShell`.
