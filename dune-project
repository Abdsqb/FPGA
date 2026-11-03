(lang dune 3.11)

(name feed_handler)

(generate_opam_files true)

(source
 (github abdsaqib/feed_handler))

(authors "Enes" "CompE teammate" "Abdullah Saqib")

(maintainers "Abdullah Saqib")

(license MIT)

(package
 (name feed_handler)
 (allow_empty)
 (synopsis "FPGA market-data feed handler in Hardcaml")
 (description
  "Parses a subset of Nasdaq ITCH 5.0 in hardware, keeps top of book in block RAM, and reports latency in clock cycles. Includes an OCaml reference model, random feed generator and testbenches.")
 (depends
  (ocaml
   (>= 5.1))
  dune
  hardcaml
  hardcaml_waveterm
  ppx_hardcaml
  ppx_jane
  (ppx_expect :with-test)))
