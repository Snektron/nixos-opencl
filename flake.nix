{
  description = "OpenCL packages for NixOS";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs";

    mesa-src = {
      url = "git+https://gitlab.freedesktop.org/mesa/mesa.git";
      flake = false;
    };

    pocl-src = {
      url = "github:pocl/pocl";
      flake = false;
    };

    shady-src = {
      url = "git+https://github.com/shady-gang/shady.git?submodules=1";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, mesa-src, pocl-src, shady-src }:
  let
    system = "x86_64-linux";
    pkgs = nixpkgs.legacyPackages.${system};
  in rec {
    packages.${system} = rec {
      spirv-llvm-translator_18 = (pkgs.spirv-llvm-translator.override {
        inherit (pkgs.llvmPackages_18) llvm;
      });

      mesa-debug-slim = (pkgs.mesa.override {
        galliumDrivers = [ "swrast" "radeonsi" "nouveau" ];
        vulkanDrivers = [ ];
        vulkanLayers = [ ];
        withValgrind = false;
        enableGalliumNine = false;
        spirv-llvm-translator = spirv-llvm-translator_18;
        llvmPackages = pkgs.llvmPackages_18;
      }).overrideAttrs (old: {
        version = "git";
        src = mesa-src;
        # Set some extra flags to create an extra slim build
        mesonFlags = (old.mesonFlags or [ ]) ++ [
          "-Dgallium-vdpau=disabled"
          "-Dgallium-va=disabled"
          "-Dgallium-xa=disabled"
          "-Dandroid-libbacktrace=disabled"
          "-Dvalgrind=disabled"
          "-Dlibunwind=disabled"
          "-Dlmsensors=disabled"
          "-Db_ndebug=false"
          "--buildtype=debug"
        ];
        # Dirty patch to make one of the nixos-upstream patches working.
        patches = [ ./patches/mesa-opencl.patch ./patches/mesa-disk-cache-key.patch ./patches/mesa-rusticl-bindgen-cpp17.patch ];
      });

      oclcpuexp-bin = pkgs.callPackage ({ stdenv, fetchurl, autoPatchelfHook, zlib, tbb_2021_11, libxml2 }:
      stdenv.mkDerivation {
        pname = "oclcpuexp-bin";
        version = "2023-WW46";

        nativeBuildInputs = [ autoPatchelfHook ];

        propagatedBuildInputs = [ zlib tbb_2021_11 libxml2 ];

        src = fetchurl {
          url = "https://github.com/intel/llvm/releases/download/2023-WW46/oclcpuexp-2023.16.10.0.17_rel.tar.gz";
          hash = "sha256-959AgccjcaHXA86xKW++BPVHUiKu0vX5tAxw1BY7lUk=";
        };

        sourceRoot = ".";

        dontConfigure = true;
        dontBuild = true;

        installPhase = ''
          mkdir -p $out/lib
          # These require some additional external libraries
          rm x64/libomptarget*
          mv x64/* $out/lib
          chmod 644 $out/lib/*
          chmod 755 $out/lib/*.so*

          mkdir -p $out/etc/OpenCL/vendors
          echo $out/lib/libintelocl.so > $out/etc/OpenCL/vendors/intelocl64.icd
        '';
      }) {};

      pocl = pkgs.callPackage ({
        stdenv,
        gcc-unwrapped,
        cmake,
        ninja,
        python3,
        llvmPackages_18,
        ocl-icd,
        libxml2,
        runCommand,
      }: let
        # POCL needs libgcc.a and libgcc_s.so. Note that libgcc_s.so is a linker script and not
        # a symlink, hence we also need libgcc_s.so.1.
        libgcc = runCommand "libgcc" {} ''
          mkdir -p $out/lib
          cp ${gcc-unwrapped}/lib/gcc/x86_64-unknown-linux-gnu/*/libgcc.a $out/lib/
          ln -s ${gcc-unwrapped.lib}/lib/libgcc_s.so $out/lib/
          ln -s ${gcc-unwrapped.lib}/lib/libgcc_s.so.1 $out/lib/
        '';
      in stdenv.mkDerivation {
        pname = "pocl";
        version = "git";

        nativeBuildInputs = [
          cmake
          ninja
          python3
          llvmPackages_18.clang
        ];

        buildInputs = with llvmPackages_18; [
          llvm
          clang-unwrapped
          clang-unwrapped.lib
          ocl-icd
          spirv-llvm-translator_18
          libxml2
        ];

        src = pocl-src;

        postPatch = ''
          substituteInPlace cmake/LLVM.cmake \
            --replace NO_CMAKE_PATH "" \
            --replace NO_CMAKE_ENVIRONMENT_PATH "" \
            --replace NO_DEFAULT_PATH ""
        '';

        cmakeFlags = [
          "-DENABLE_ICD=ON"
          "-DENABLE_TESTS=OFF"
          "-DENABLE_EXAMPLES=OFF"
          # Required to make POCL play nice with Mesa
          # See https://github.com/pocl/pocl/blob/main/README.packaging
          "-DSTATIC_LLVM=ON"
          "-DEXTRA_HOST_LD_FLAGS=-L${libgcc}/lib"
        ];
      }) {};

      shady = pkgs.callPackage ({
        stdenv,
        cmake,
        ninja,
        llvmPackages_18,
        libxml2,
        json_c,
      }: stdenv.mkDerivation {
        pname = "shady";
        version = "git";

        src = shady-src;

        nativeBuildInputs = [
          cmake
          ninja
        ];

        buildInputs = [
          llvmPackages_18.clang
          llvmPackages_18.llvm
          libxml2
          json_c
        ];

        cmakeFlags = [
          "-DCMAKE_BUILD_WITH_INSTALL_RPATH=ON"
          "-DCMAKE_INSTALL_RPATH_USE_LINK_PATH=ON"
        ];

        patches = [ ./patches/shady.patch ];

        postInstall = ''
          patchelf --allowed-rpath-prefixes /nix --shrink-rpath $out/bin/vcc
          patchelf --allowed-rpath-prefixes /nix --shrink-rpath $out/bin/slim
        '';
      }) {};

      spirv2clc = pkgs.callPackage ({
        stdenv,
        fetchFromGitHub,
        cmake,
        ninja,
        python3
      }: stdenv.mkDerivation {
        pname = "spirv2clc";
        version = "0.1";

        src = fetchFromGitHub {
          owner = "kpet";
          repo = "spirv2clc";
          rev = "b7972d03a707a6ad1b54b96ab1437c5cd1594a43";
          sha256 = "sha256-IYaJRsS4VpGHPJzRhjIBXlCoUWM44t84QV5l7PKSaJk=";
          fetchSubmodules = true;
        };

        nativeBuildInputs = [ cmake ninja python3];

        installPhase = ''
          ninja install
          # not installed by default for some reason
          mkdir -p $out/bin
          mv tools/spirv2clc $out/bin/spirv2clc
        '';
      }) {};

      ocl-vendors = pkgs.runCommand "ocl-vendors" {} ''
        mkdir -p $out/etc/OpenCL/vendors
        cp ${packages.${system}.mesa-debug-slim.opencl}/etc/OpenCL/vendors/rusticl.icd $out/etc/OpenCL/vendors/
        cp ${pkgs.rocm-opencl-icd}/etc/OpenCL/vendors/amdocl64.icd $out/etc/OpenCL/vendors/
        cp ${packages.${system}.oclcpuexp-bin}/etc/OpenCL/vendors/intelocl64.icd $out/etc/OpenCL/vendors/
        cp ${packages.${system}.pocl}/etc/OpenCL/vendors/pocl.icd $out/etc/OpenCL/vendors/
      '';
    };

    devShells.${system}.default = let
      ld_library_path = pkgs.lib.makeLibraryPath [
        pkgs.khronos-ocl-icd-loader
      ];
    in pkgs.mkShell {
      name = "opencl";

      packages = [
        pkgs.khronos-ocl-icd-loader
        pkgs.clinfo
        pkgs.opencl-headers
        pkgs.spirv-tools
        packages.${system}.spirv-llvm-translator_18
        packages.${system}.shady
        packages.${system}.spirv2clc
      ];

      shellHook = ''
        # Don't enable radeonsi:0 by default because if something goes wrong it may crash the host
        export RUSTICL_ENABLE=swrast:0
        export LD_LIBRARY_PATH="$LD_LIBRARY_PATH:${ld_library_path}"
        export OCL_ICD_VENDORS="${packages.${system}.ocl-vendors}/etc/OpenCL/vendors/";
      '';
    };
  };
}
