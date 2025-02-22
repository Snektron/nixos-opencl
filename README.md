# NixOS OpenCL development flake

This flake contains a dev shell with a bunch of OpenCL drivers and tooling. It contains some stuff that is not found in nixpkgs and attempts to provide more recent versions of the things that are. It works on aarch64-linux and x86_64 based platform. A number of development shells are available from this flake:

- `mesa`: A debug build of the master branch of [mesa](https://gitlab.freedesktop.org/mesa/mesa/). Note that the RustiCL backend is set to `swrast:0` by default, set the `RUSTICL_ENABLE` environment variable to override that. Zink requires a Vulkan driver to be available on the system, this can either be provided by the system or the `mesa-vulkan` shell.
- `intel-cpu` (x86_64 only): The Intel OpenCL CPU runtime from DPC++, version 2025.0.4-1519.
- `pocl`: A build of the master branch of [POCL](https://github.com/pocl/pocl).
- `clvk`: [clvk](https://github.com/kpet/clvk)
- `rocm`: The regular NixOS ROCm OpenCL ICD.

Additionally, the default shell contains all of the above including some extra utilities:
- [shady](https://github.com/shady-gang/shady)
- [spirv2clc](https://github.com/kpet/spirv2clc)
- [SPIRV-LLVM-Translator](https://github.com/KhronosGroup/SPIRV-LLVM-Translator/)

## Usage

To use this dev shell from another flake, first import it as usual and then use `inputsFrom = [ nixos-opencl.devShells.${system}.<the shell you want> ];` in your `mkShell`. See previous section for available shells. It can also be used with `nix develop .#<shell>` of course.
