SpeexDSP 1.2.1 (https://github.com/xiph/speexdsp, tag `SpeexDSP-1.2.1`), BSD
licensed (`COPYING`): only the echo canceller (`mdf.c`) and the preprocessor
that suppresses its residual echo (`preprocess.c`), with the KISS FFT they run
on. Built in floating point (`FLOATING_POINT`, `USE_KISS_FFT`; see
`Package.swift`). `speexdsp_config_types.h` is written by hand in place of the
one `configure` generates.

Used only by hands-free's experimental echo cancellation on the Mac
(`HandsFree/EchoCanceller.swift`).
