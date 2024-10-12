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

    clvk-src = {
      url = "git+https://github.com/kpet/clvk.git?submodules=1";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, mesa-src, pocl-src, shady-src, clvk-src }:
  let
    system = "x86_64-linux";
    pkgs = nixpkgs.legacyPackages.${system};
    lib = pkgs.lib;
  in rec {
    packages.${system} = rec {
      spirv-llvm-translator_18 = (pkgs.spirv-llvm-translator.override {
        inherit (pkgs.llvmPackages_18) llvm;
      });

      mesa-debug-slim = (pkgs.mesa.override {
        galliumDrivers = [ "iris" "swrast" "nouveau" "radeonsi" "zink" ];
        vulkanDrivers = [ ];
        vulkanLayers = [ ];
        withValgrind = false;
        spirv-llvm-translator = spirv-llvm-translator_18;
        llvmPackages = pkgs.llvmPackages_18;
      }).overrideAttrs (old: {
        version = "git";
        src = mesa-src;
        # Set some extra flags to create an extra slim build
        mesonFlags =
          builtins.filter
            # These flags seem no longer requied
            (flag: !(lib.strings.hasInfix "omx-libs-path" flag || lib.strings.hasInfix "dri-search-path" flag))
            (old.mesonFlags or [ ]) ++ [
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

        # This `patchelf --add-rpath ${vulkan-loader}/lib $out/lib/libgallium*.so`
        # doesn't work with the current version of mesa, so remove it. Likely this
        # needs to actually be zink_dri.so. For now, it seems that Zink is fine
        # with using the system Vulkan.
        postFixup =
          lib.strings.concatStringsSep
            "\n"
            (builtins.filter
              (line: !(lib.strings.hasInfix "$out/lib/libgallium*.so" line))
              (lib.strings.splitString "\n" old.postFixup));

        # We don't care about microsoft here.
        outputs =
          builtins.filter
            (x: x != "spirv2dxil")
            old.outputs;
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
        pkg-config
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
          pkg-config
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
          "-DSHADY_ENABLE_SAMPLES=OFF"
          "-DSHADY_USE_FETCHCONTENT=OFF"
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

      clvk = pkgs.callPackage ({
        stdenv,
        cmake,
        ninja,
        python3,
        llvmPackages_18,
        spirv-tools,
        vulkan-headers,
        vulkan-loader,
        shaderc,
        glslang,
        fetchpatch,
      }: stdenv.mkDerivation {
        pname = "clvk";
        version = "git";

        src = clvk-src;

        nativeBuildInputs = [ cmake ninja python3 shaderc glslang ];

        buildInputs = [
          llvmPackages_18.llvm
          vulkan-headers
          vulkan-loader
        ];

        patches = [
          (fetchpatch {
            url = "https://github.com/google/clspv/pull/1328/commits/a34649351ffb7d047f443b3899955f8529f30d55.patch";
            hash = "sha256-DIYGI17Vqe9UzN55eWhRF/3BBBhOVxy7fNY6IWVTdO0=";
            stripLen = 1;
            extraPrefix = "external/clspv/";
            excludes = [ "external/clspv/deps.json" ];
            revert = true;
          })
        ];

        postPatch = ''
          substituteInPlace external/clspv/lib/CMakeLists.txt \
            --replace ''$\{CLSPV_LLVM_BINARY_DIR\}/lib/cmake/clang/ClangConfig.cmake \
              ${llvmPackages_18.clang-unwrapped.dev}/lib/cmake/clang/ClangConfig.cmake

          substituteInPlace external/clspv/CMakeLists.txt \
            --replace ''$\{CLSPV_LLVM_BINARY_DIR\}/tools/clang/include \
              ${llvmPackages_18.clang-unwrapped.dev}/include

          # The in-tree build hardcodes a path to the build directory
          # just override it with our proper out-of-tree version
          substituteInPlace src/config.def \
            --replace DEFAULT_LLVMSPIRV_BINARY_PATH \"${spirv-llvm-translator_18}/bin/llvm-spirv\" \
            --replace DEFAULT_CLSPV_BINARY_PATH \"$out/clspv\"
        '';

        cmakeFlags = let
          # This file is required but its not supplied by LLVM 18, it was only added by LLVM 19.
          llvm_version = pkgs.writeTextDir "LLVMVersion.cmake"
            ''
            # The LLVM Version number information

            if(NOT DEFINED LLVM_VERSION_MAJOR)
              set(LLVM_VERSION_MAJOR ${lib.versions.major llvmPackages_18.llvm.version})
            endif()
            if(NOT DEFINED LLVM_VERSION_MINOR)
              set(LLVM_VERSION_MINOR ${lib.versions.minor llvmPackages_18.llvm.version})
            endif()
            if(NOT DEFINED LLVM_VERSION_PATCH)
              set(LLVM_VERSION_PATCH ${lib.versions.patch llvmPackages_18.llvm.version})
            endif()
            if(NOT DEFINED LLVM_VERSION_SUFFIX)
              set(LLVM_VERSION_SUFFIX git)
            endif()
            '';
        in [
          "-DCLVK_CLSPV_ONLINE_COMPILER=ON"
          "-DCLVK_BUILD_TESTS=OFF" # Missing: llvm_gtest
          # clspv
          "-DEXTERNAL_LLVM=1"
          "-DCLSPV_LLVM_SOURCE_DIR=${llvmPackages_18.llvm.src}/llvm"
          "-DCLSPV_CLANG_SOURCE_DIR=${llvmPackages_18.clang-unwrapped.src}/clang"
          "-DCLSPV_LLVM_CMAKE_MODULES_DIR=${llvm_version}"
          "-DCLSPV_LIBCLC_SOURCE_DIR=${llvmPackages_18.libclc.src}/libclc"
          "-DCLSPV_LLVM_BINARY_DIR=${llvmPackages_18.llvm.dev}"
          "-DCLSPV_EXTERNAL_LIBCLC_DIR=${llvmPackages_18.libclc}/share/clc"
          # SPIRV-LLVM-Translator
          "-DBASE_LLVM_VERSION=${llvmPackages_18.llvm.version}"
          "-DLLVM_SPIRV_SOURCE=${spirv-llvm-translator_18.src}"
        ];

        postInstall = ''
          mkdir -p $out/etc/OpenCL/vendors
          echo $out/libOpenCL.so > $out/etc/OpenCL/vendors/clvk.icd
        '';
      }) {};
    };

    devShells.${system} = let
      ld_library_path = lib.makeLibraryPath [
        pkgs.khronos-ocl-icd-loader
      ];

      mkDevShell = { name, vendors, extraShellHook ? "", packages ? [] }: pkgs.mkShell {
        name = "nix-opencl-${name}";

        packages = [
          pkgs.khronos-ocl-icd-loader
          pkgs.clinfo
          pkgs.opencl-headers
          pkgs.spirv-tools
        ] ++ packages;

        shellHook = ''
          export LD_LIBRARY_PATH="$LD_LIBRARY_PATH:${ld_library_path}"
          export OCL_ICD_VENDORS="${vendors}/etc/OpenCL/vendors/"
          ${extraShellHook}
        '';
      };

      shells = {
        mesa = {
          vendors = packages.${system}.mesa-debug-slim.opencl;
          extraShellHook = ''
            # Don't enable radeonsi:0 by default because if something goes wrong it may crash the host
            export RUSTICL_ENABLE=swrast:0
          '';
        };

        pocl = {
          vendors = packages.${system}.pocl;
        };

        intel-cpu = {
          vendors = packages.${system}.oclcpuexp-bin;
        };

        rocm = {
          vendors = pkgs.rocm-opencl-icd;
        };

        clvk = {
          vendors = packages.${system}.clvk;
        };
      };
    in
      (builtins.mapAttrs
        (name: options: mkDevShell (options // { inherit name; }))
        shells)
    // {
      # The default shell has everything from the above shells combined.
      default = mkDevShell {
        name = "all";

        vendors = pkgs.symlinkJoin {
          name = "ocl-vendors-combined";
          paths = lib.attrsets.mapAttrsToList (name: options: options.vendors) shells;
        };

        packages = (lib.attrsets.mapAttrsToList (name: options: options.packages or []) shells) ++ [
          packages.${system}.spirv-llvm-translator_18
          packages.${system}.shady
          packages.${system}.spirv2clc
        ];

        extraShellHook =
          lib.strings.concatStringsSep
            "\n"
            (lib.attrsets.mapAttrsToList
              (name: options: options.extraShellHook or "")
              shells);
      };
    };
  };
}
