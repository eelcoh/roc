# META
~~~ini
description=F32/F64 arithmetic, comparisons, and F64 to I64 conversion in host-called functions
type=dev_object
~~~
# SOURCE
## app.roc
~~~roc
app [main] { pf: platform "./platform.roc" }

main : F64, F32, I64 -> I64
main = |x, y, n| {
    scaled = x * 2.5 - I64.to_f64(n) / 3.0
    narrowed = F32.to_f64(y * 1.5 + 0.25)
    total = if scaled > narrowed { scaled - narrowed } else { narrowed + scaled }
    F64.to_i64_wrap(total)
}
~~~
## platform.roc
~~~roc
platform ""
    requires {} { main : F64, F32, I64 -> I64 }
    exposes []
    packages {}
    provides { "roc_main": main_for_host }
    targets: {
        inputs_dir: "targets/",
        x64glibc: { inputs: [app] },
    }

main_for_host : F64, F32, I64 -> I64
main_for_host = main
~~~
# MONO
~~~roc
# platform
main_for_host = <required>

# app
main = |x, y, n| {
	scaled = x * 2.5 - to_f64(n) / 3
	narrowed = to_f64(y * 1.5 + 0.25)
	total = if (scaled > narrowed) {
		scaled - narrowed
	} else {
		narrowed + scaled
	}
	to_i64_wrap(total)
}

~~~
# DEV OUTPUT
~~~ini
x64mac=ce0c5f3728120b1cd8055bfbf661de772c950e5d09250a75963b95e567710a65
x64win=57564a98a074b7ff523e987a4f81ee124622aee05546268c2b523a794216a376
x64mingw=57564a98a074b7ff523e987a4f81ee124622aee05546268c2b523a794216a376
x64freebsd=4515a811743c059a869a9b0a5119efcd364dae568a5b0f9d27d1c57df8dc13fb
x64openbsd=a1fb5f7fb5edda1e228392b3d24e4db30e19f92467c064756a7cf95f85a3c6f3
x64netbsd=0a9fcb0086dddd589fbbdd2ad8c89c9a45140bd38dd262de0b726be4e2c9e357
x64musl=0a9fcb0086dddd589fbbdd2ad8c89c9a45140bd38dd262de0b726be4e2c9e357
x64glibc=0a9fcb0086dddd589fbbdd2ad8c89c9a45140bd38dd262de0b726be4e2c9e357
x64linux=0a9fcb0086dddd589fbbdd2ad8c89c9a45140bd38dd262de0b726be4e2c9e357
x64elf=0a9fcb0086dddd589fbbdd2ad8c89c9a45140bd38dd262de0b726be4e2c9e357
x64v1mac=ce0c5f3728120b1cd8055bfbf661de772c950e5d09250a75963b95e567710a65
x64v1win=57564a98a074b7ff523e987a4f81ee124622aee05546268c2b523a794216a376
x64v1mingw=57564a98a074b7ff523e987a4f81ee124622aee05546268c2b523a794216a376
x64v1freebsd=4515a811743c059a869a9b0a5119efcd364dae568a5b0f9d27d1c57df8dc13fb
x64v1openbsd=a1fb5f7fb5edda1e228392b3d24e4db30e19f92467c064756a7cf95f85a3c6f3
x64v1netbsd=0a9fcb0086dddd589fbbdd2ad8c89c9a45140bd38dd262de0b726be4e2c9e357
x64v1musl=0a9fcb0086dddd589fbbdd2ad8c89c9a45140bd38dd262de0b726be4e2c9e357
x64v1glibc=0a9fcb0086dddd589fbbdd2ad8c89c9a45140bd38dd262de0b726be4e2c9e357
x64v1linux=0a9fcb0086dddd589fbbdd2ad8c89c9a45140bd38dd262de0b726be4e2c9e357
x64v1elf=0a9fcb0086dddd589fbbdd2ad8c89c9a45140bd38dd262de0b726be4e2c9e357
arm64mac=41de8394e59af21099324e2b8e6ac5e0721b8dc04d07ea1ef1fb9d69df4192d3
arm64win=3788f82bd199f3d5e0ca78498add8eb410612cfdaad5eb64ce800dc3824f8f5b
arm64mingw=3788f82bd199f3d5e0ca78498add8eb410612cfdaad5eb64ce800dc3824f8f5b
arm64linux=4064342091f8513864fcecd5767fea7b8bce54fbcda99639f88e3131a21bc120
arm64musl=4064342091f8513864fcecd5767fea7b8bce54fbcda99639f88e3131a21bc120
arm64glibc=4064342091f8513864fcecd5767fea7b8bce54fbcda99639f88e3131a21bc120
arm64v1win=3788f82bd199f3d5e0ca78498add8eb410612cfdaad5eb64ce800dc3824f8f5b
arm64v1mingw=3788f82bd199f3d5e0ca78498add8eb410612cfdaad5eb64ce800dc3824f8f5b
arm64v1linux=4064342091f8513864fcecd5767fea7b8bce54fbcda99639f88e3131a21bc120
arm64v1musl=4064342091f8513864fcecd5767fea7b8bce54fbcda99639f88e3131a21bc120
arm64v1glibc=4064342091f8513864fcecd5767fea7b8bce54fbcda99639f88e3131a21bc120
arm32linux=NOT_IMPLEMENTED
arm32musl=NOT_IMPLEMENTED
wasm32=NOT_IMPLEMENTED
wasm32v1=NOT_IMPLEMENTED
~~~
