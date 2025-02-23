{
  description = "OpenCL packages for NixOS";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-24.11";

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

    zig-src = {
      url = "git+https://github.com/ziglang/zig";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, mesa-src, pocl-src, shady-src, clvk-src, zig-src }:
  let
    systems = [ "x86_64-linux" "aarch64-linux" ];
    lib = nixpkgs.lib;
    forAllSystems = f: lib.genAttrs systems (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
      in f system pkgs);
  in rec {
    packages = forAllSystems (system: pkgs: {
      llvmPackages = pkgs.llvmPackages_19;

      # The SPIR-V headers source is used during building of spirv-tools,
      # so to add the Zig experimental grammar we have to patch the source
      # and not just the installation of spirv-headers...
      spirv-headers-src = pkgs.callPackage ({
        stdenv,
        fetchFromGitHub
      }: stdenv.mkDerivation rec {
        pname = "spirv-headers-src";
        version = "1.4.304.1";
        src = pkgs.fetchFromGitHub {
          owner = "KhronosGroup";
          repo = "SPIRV-Headers";
          rev = "54a521dd130ae1b2f38fef79b09515702d135bdd";
          hash = "sha256-PScDq8HhQPFUs78N75QyL9oEykmjZmAhdxCAqQ0LJds=";
        };

        dontConfigure = true;
        dontBuild = true;

        postPatch = ''
          # Add the Zig experimental extinst set
          cp ${zig-src}/src/codegen/spirv/extinst.zig.grammar.json include/spirv/unified1/
        '';

        installPhase = ''
          cp -r . $out
        '';
      }) {};

      spirv-headers = pkgs.spirv-headers.overrideAttrs (old: rec {
        version = "1.4.304.1";
        src = packages.${system}.spirv-headers-src;
      });

      spirv-tools = (pkgs.spirv-tools.override {
        inherit (packages.${system}) spirv-headers;
        # Compilation with stdenv causes ICE for some reason
        stdenv = pkgs.clang19Stdenv;
      }).overrideAttrs (old: rec {
        version = "1.4.304.1";
        src = pkgs.fetchFromGitHub {
          owner = "Snektron";
          repo = "SPIRV-Tools";
          rev = "e2fa6b83ac26c0545a7405e08b4ded7a34eeeed0";
          hash = "sha256-0/aSkPQp+jWXcRJmI4zyfufhyhX5Egiza0pCbtoeyPQ=";
        };

        patches = [ ./patches/spirv-tools.patch ];
      });

      spirv-llvm-translator = pkgs.spirv-llvm-translator.override {
        inherit (packages.${system}.llvmPackages) llvm;
        inherit (packages.${system}) spirv-headers spirv-tools;
      };

      mesa = (pkgs.mesa.override {
        withValgrind = false;
        inherit (packages.${system}) llvmPackages spirv-tools spirv-llvm-translator;
        # Compilation with stdenv segfaults for some reason
        stdenv = pkgs.gcc14Stdenv;
      }).overrideAttrs (old: {
        version = "git";
        src = mesa-src;
        # Set some extra flags to create an extra slim build
        mesonFlags =
          builtins.filter
            # These flags are no longer valid.
            (flag: !(lib.strings.hasInfix "omx-libs-path" flag || lib.strings.hasInfix "dri-search-path" flag || lib.strings.hasInfix "opencl-spirv" flag))
            (old.mesonFlags or [ ]) ++ [
              "-Db_ndebug=false"
              "--buildtype=debug"
            ];

        # Dirty patch to make one of the nixos-upstream patches working.
        patches = [ ./patches/mesa-opencl.patch ];

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

        dontStrip = true;
      });

      pocl = pkgs.callPackage ({
        stdenv,
        gcc-unwrapped,
        cmake,
        ninja,
        python3,
        llvmPackages,
        ocl-icd,
        libxml2,
        runCommand,
        pkg-config,
        spirv-llvm-translator,
        opencl-headers,
        hwloc,
        spirv-tools
      }: let
        # POCL needs libgcc.a and libgcc_s.so. Note that libgcc_s.so is a linker script and not
        # a symlink, hence we also need libgcc_s.so.1.
        libgcc = runCommand "libgcc" {} ''
          mkdir -p $out/lib
          cp ${gcc-unwrapped}/lib/gcc/*/*/libgcc.a $out/lib/
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
          llvmPackages.clang
        ];

        buildInputs = with llvmPackages; [
          llvm
          clang-unwrapped
          clang-unwrapped.lib
          ocl-icd
          spirv-llvm-translator
          libxml2
          pkg-config
          opencl-headers
          spirv-tools
          hwloc
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
      }) {
        inherit (packages.${system}) llvmPackages spirv-llvm-translator spirv-tools;
        stdenv = pkgs.clang19Stdenv;
      };

      shady = pkgs.callPackage ({
        stdenv,
        cmake,
        ninja,
        llvmPackages,
        libxml2,
        json_c,
        python3
      }: stdenv.mkDerivation {
        pname = "shady";
        version = "git";

        src = shady-src;

        nativeBuildInputs = [
          cmake
          ninja
          python3
        ];

        buildInputs = [
          llvmPackages.clang
          llvmPackages.llvm
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

        postPatch = ''
          patchShebangs SPIRV-Headers/tools/buildHeaders/bin/generate_language_headers.py
        '';

        postInstall = ''
          patchelf --allowed-rpath-prefixes /nix --shrink-rpath $out/bin/vcc
          patchelf --allowed-rpath-prefixes /nix --shrink-rpath $out/bin/slim
        '';
      }) {
        inherit (packages.${system}) llvmPackages;
      };

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
        llvmPackages,
        spirv-tools,
        vulkan-headers,
        vulkan-loader,
        shaderc,
        glslang,
        fetchpatch,
        spirv-llvm-translator
      }: stdenv.mkDerivation {
        pname = "clvk";
        version = "git";

        src = clvk-src;

        nativeBuildInputs = [ cmake ninja python3 shaderc glslang ];

        buildInputs = [
          llvmPackages.llvm
          vulkan-headers
          vulkan-loader
        ];

        patches = [
          (fetchpatch {
            url = "https://github.com/google/clspv/commit/022d17206ec3aca899f72593b8f3d2bf5b5192ec.patch";
            hash = "sha256-RJX4/Eec7UUFED7zudJTAORPjXSUdTKi/YXhIdk/kxU=";
            stripLen = 1;
            extraPrefix = "external/clspv/";
            revert = true;
          })
          (fetchpatch {
            url = "https://github.com/google/clspv/commit/419bc4ba6d1b6ff01c8f2f8ac2306307d9022cc9.patch";
            hash = "sha256-VzP6/oU3POtxDZ3kH/0IoUTmUzB+Lo3KmQD2ajsq0ko=";
            stripLen = 1;
            extraPrefix = "external/clspv/";
            excludes = [ "external/clspv/deps.json" ];
            revert = true;
          })
          (fetchpatch {
            url = "https://github.com/google/clspv/commit/48acbf93dccdfca586210713d9d55cde40e40b54.patch";
            hash = "sha256-d8JKmKxLQa6Vxzw0cLXG/ldpxCZ4Iml5w2Tn4aSeCmQ=";
            stripLen = 1;
            extraPrefix = "external/clspv/";
            excludes = [ "external/clspv/deps.json" ];
            revert = true;
          })
          (fetchpatch {
            url = "https://github.com/google/clspv/commit/ae643967b8a7b0402420b95cf101c179fe059f45.patch";
            hash = "sha256-Czu06caNJjFBVSg6uoWFPJQul8Hhqi/hou/AcymVhI4=";
            stripLen = 1;
            extraPrefix = "external/clspv/";
            excludes = [ "external/clspv/deps.json" ];
            revert = true;
          })
          (fetchpatch {
            url = "https://github.com/google/clspv/commit/b8c19faca7317d64922396aa2ee44029dbf38b7c.patch";
            hash = "sha256-S2SmeM84XU9Wd2XA3DFmBXK2AEz4tClOgaEGHPoBBaY=";
            stripLen = 1;
            extraPrefix = "external/clspv/";
            excludes = [ "external/clspv/deps.json" ];
            revert = true;
          })
          (fetchpatch {
            url = "https://github.com/google/clspv/commit/7bfeccd7be6ea317c07de9f8d7ceb86cb2579d20.patch";
            hash = "sha256-qys2hQyciQmkvaD1LF4qoGxbUD0qiO0DTY7ryY+HalU=";
            stripLen = 1;
            extraPrefix = "external/clspv/";
            excludes = [ "external/clspv/deps.json" ];
            revert = true;
          })
        ];

        postPatch = ''
          substituteInPlace external/clspv/lib/CMakeLists.txt \
            --replace ''$\{CLSPV_LLVM_BINARY_DIR\}/lib/cmake/clang/ClangConfig.cmake \
              ${llvmPackages.clang-unwrapped.dev}/lib/cmake/clang/ClangConfig.cmake

          substituteInPlace external/clspv/CMakeLists.txt \
            --replace ''$\{CLSPV_LLVM_BINARY_DIR\}/tools/clang/include \
              ${llvmPackages.clang-unwrapped.dev}/include

          # The in-tree build hardcodes a path to the build directory
          # just override it with our proper out-of-tree version
          substituteInPlace src/config.def \
            --replace DEFAULT_LLVMSPIRV_BINARY_PATH \"${spirv-llvm-translator}/bin/llvm-spirv\" \
            --replace DEFAULT_CLSPV_BINARY_PATH \"$out/clspv\"
        '';

        cmakeFlags = let
          # This file is required but its not supplied by LLVM 18, it was only added by LLVM 19.
          llvm_version = pkgs.writeTextDir "LLVMVersion.cmake"
            ''
            # The LLVM Version number information

            if(NOT DEFINED LLVM_VERSION_MAJOR)
              set(LLVM_VERSION_MAJOR ${lib.versions.major llvmPackages.llvm.version})
            endif()
            if(NOT DEFINED LLVM_VERSION_MINOR)
              set(LLVM_VERSION_MINOR ${lib.versions.minor llvmPackages.llvm.version})
            endif()
            if(NOT DEFINED LLVM_VERSION_PATCH)
              set(LLVM_VERSION_PATCH ${lib.versions.patch llvmPackages.llvm.version})
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
          "-DCLSPV_LLVM_SOURCE_DIR=${llvmPackages.llvm.src}/llvm"
          "-DCLSPV_CLANG_SOURCE_DIR=${llvmPackages.clang-unwrapped.src}/clang"
          "-DCLSPV_LLVM_CMAKE_MODULES_DIR=${llvm_version}"
          "-DCLSPV_LIBCLC_SOURCE_DIR=${llvmPackages.libclc.src}/libclc"
          "-DCLSPV_LLVM_BINARY_DIR=${llvmPackages.llvm.dev}"
          "-DCLSPV_EXTERNAL_LIBCLC_DIR=${llvmPackages.libclc}/share/clc"
          # SPIRV-LLVM-Translator
          "-DBASE_LLVM_VERSION=${llvmPackages.llvm.version}"
          "-DLLVM_SPIRV_SOURCE=${spirv-llvm-translator.src}"
        ];

        postInstall = ''
          mkdir -p $out/etc/OpenCL/vendors
          echo $out/libOpenCL.so > $out/etc/OpenCL/vendors/clvk.icd
        '';
      }) {
        inherit (packages.${system}) llvmPackages spirv-llvm-translator spirv-tools;
        stdenv = pkgs.clang19Stdenv;
      };
    } // lib.attrsets.optionalAttrs (pkgs.stdenv.hostPlatform.isx86_64) {
      intel-oneapi-runtime-compilers = pkgs.callPackage ({
        stdenv,
        fetchurl,
        autoPatchelfHook,
        dpkg
      }: stdenv.mkDerivation rec {
        pname = "intel-oneapi-runtime-compilers";
        version = "2025.0.4-1519";

        src = fetchurl {
          url = "https://apt.repos.intel.com/oneapi/pool/main/${pname}-${version}_amd64.deb";
          hash = "sha256-L2Tb74/ybDgW60eRRFVZIvGmwKfs6/zaxawzEd5J+gA=";
        };

        nativeBuildInputs = [ autoPatchelfHook dpkg ];

        dontConfigure = true;
        dontBuild = true;

        unpackPhase = "dpkg -x $src ./";

        installPhase = ''
          mkdir -p $out/lib
          for f in "libimf.so" "libintlc.so" "libintlc.so.5" "libirng.so" "libsvml.so"; do
            mv opt/intel/oneapi/redist/lib/$f $out/lib/
          done
          ls -alh $out/lib
        '';
      }) {};

      # NixOS' tbb doesn't work properly.
      intel-oneapi-runtime-tbb = pkgs.callPackage ({
        stdenv,
        fetchurl,
        autoPatchelfHook,
        dpkg,
        hwloc
      }: stdenv.mkDerivation rec {
        pname = "intel-oneapi-runtime-tbb";
        version = "2022.0.0-402";

        src = fetchurl {
          url = "https://apt.repos.intel.com/oneapi/pool/main/${pname}-${version}_amd64.deb";
          hash = "sha256-tmdMCXKiC+2P3Pjfb+jaDwyYeknVxUSRvQeasmZnuxA=";
        };

        nativeBuildInputs = [ autoPatchelfHook dpkg ];
        buildInputs = [ stdenv.cc.cc.lib hwloc.lib ];

        dontConfigure = true;
        dontBuild = true;

        unpackPhase = "dpkg -x $src ./";

        installPhase = ''
          mkdir -p $out/lib
          ls
          mv opt/intel/oneapi/redist/lib/libtbb.so* $out/lib/
        '';
      }) {};

      intel-oneapi-runtime-openmp-opencl-shared = pkgs.callPackage ({
        stdenv,
        fetchurl,
        autoPatchelfHook,
        dpkg,
        gcc-unwrapped
      }: stdenv.mkDerivation rec {
        pname = "intel-oneapi-runtime-openmp-opencl-shared";
        version = "2025.0.4-1519";

        src = fetchurl {
          url = "https://apt.repos.intel.com/oneapi/pool/main/${pname}-${version}_amd64.deb";
          hash = "sha256-KQAHBUggsKem6EsVWguJo27GpqZt2XHJyfBRcFf2gz8=";
        };

        nativeBuildInputs = [ autoPatchelfHook dpkg ];
        buildInputs = [ gcc-unwrapped.lib stdenv.cc.cc.lib ];

        dontConfigure = true;
        dontBuild = true;

        unpackPhase = "dpkg -x $src ./";

        installPhase = ''
          mkdir -p $out/lib
          mv opt/intel/oneapi/redist/lib/* $out/lib/
        '';
      }) {};

      intel-oneapi-runtime-dpcpp-sycl-opencl-cpu = pkgs.callPackage ({
        stdenv,
        fetchurl,
        autoPatchelfHook,
        zlib,
        dpkg,
        intel-oneapi-runtime-tbb,
        intel-oneapi-runtime-compilers,
        intel-oneapi-runtime-openmp-opencl-shared
      }: stdenv.mkDerivation rec {
        pname = "intel-oneapi-runtime-dpcpp-sycl-opencl-cpu";
        version = "2025.0.4-1519";

        src = fetchurl {
          url = "https://apt.repos.intel.com/oneapi/pool/main/${pname}-${version}_amd64.deb";
          hash = "sha256-DT+ZD22NHBmk27Mkds1nFWvh/pArjdQmt7+T150AXVA=";
        };

        nativeBuildInputs = [ autoPatchelfHook dpkg ];
        buildInputs = [ zlib intel-oneapi-runtime-tbb intel-oneapi-runtime-compilers intel-oneapi-runtime-openmp-opencl-shared ];

        dontConfigure = true;
        dontBuild = true;

        unpackPhase = "dpkg -x $src ./";

        installPhase = ''
          mkdir -p $out/lib
          mv opt/intel/oneapi/redist/lib/* $out/lib/

          mkdir -p $out/etc/OpenCL/vendors
          echo $out/lib/libintelocl.so > $out/etc/OpenCL/vendors/intel-cpu.icd

          echo "CL_CONFIG_DEVICES = cpu" > $out/lib/cl.cfg
        '';
      }) {
        inherit (packages.${system}) intel-oneapi-runtime-compilers intel-oneapi-runtime-openmp-opencl-shared intel-oneapi-runtime-tbb;
      };
    });

    devShells = forAllSystems (system: pkgs:
    let
      ld_library_path = lib.makeLibraryPath [
        pkgs.khronos-ocl-icd-loader
      ];

      mkDevShell = { name, vendors, extraShellHook ? "", extraPackages ? [] }: pkgs.mkShell {
        name = "nix-opencl-${name}";

        packages = [
          pkgs.khronos-ocl-icd-loader
          pkgs.clinfo
          pkgs.opencl-headers
          packages.${system}.spirv-tools
        ] ++ extraPackages;

        shellHook = ''
          export LD_LIBRARY_PATH="$LD_LIBRARY_PATH:${ld_library_path}"
          export OCL_ICD_VENDORS="${vendors}/etc/OpenCL/vendors/"
          ${extraShellHook}
        '';
      };

      shells = {
        mesa = {
          vendors = packages.${system}.mesa.opencl;
          extraShellHook = ''
            # Don't enable radeonsi:0 by default because if something goes wrong it may crash the host
            export RUSTICL_ENABLE=swrast:0
          '';
        };

        pocl = {
          vendors = packages.${system}.pocl;
        };

        clvk = {
          vendors = packages.${system}.clvk;
        };
      } // lib.attrsets.optionalAttrs (pkgs.stdenv.hostPlatform.isx86_64) {
        rocm = {
          vendors = pkgs.rocmPackages.clr;
        };

        intel-cpu = {
          vendors = packages.${system}.intel-oneapi-runtime-dpcpp-sycl-opencl-cpu;
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

        extraPackages = (lib.attrsets.mapAttrsToList (name: options: options.packages or []) shells) ++ [
          packages.${system}.spirv-llvm-translator
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

      # This environment can be used to get our mesa build's Vulkan drivers too
      mesa-vulkan = let
        mesa_icd_dir = "${packages.${system}.mesa.drivers}/share/vulkan/icd.d";
        icds = pkgs.lib.strings.concatStringsSep ":" [
          "${mesa_icd_dir}/radeon_icd.x86_64.json"
          "${mesa_icd_dir}/lvp_icd.x86_64.json"
        ];
      in pkgs.mkShell {
        packages = [
          self.packages.${system}.mesa.drivers
        ];

        shellHook = ''
          export VK_DRIVER_FILES=${icds}
        '';
      };
    });
  };
}
