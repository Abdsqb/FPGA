open Model

let read_mold_file path =
  match In_channel.with_open_bin path In_channel.input_all with
  | exception Sys_error e -> Error e
  | contents -> Itch.unframe_all (Bytes.of_string contents)

(* Same per-message header as gen_feed, so both tools make identical bytes. *)
let encode_numbered i m =
  let header = { Itch.default_header with tracking = i land 0xFFFF; timestamp_ns = i } in
  Itch.encode ~header ~match_number:i m

let rec take k = function
  | [] -> [], []
  | l when k = 0 -> [], l
  | x :: rest ->
    let a, b = take (k - 1) rest in
    x :: a, b

let generate ?(msgs_per_packet = 0) ~seed ~n () =
  let cfg = { Feed_gen.default_config with seed } in
  let msgs = List.mapi (fun i m -> encode_numbered (i + 1) m) (Feed_gen.generate cfg n) in
  if msgs_per_packet <= 0 then Mold.packetize ~first_seq:1 msgs
  else
    let rec group seq acc = function
      | [] -> List.rev acc
      | l ->
        let chunk, rest = take msgs_per_packet l in
        group (seq + List.length chunk) (Mold.encode ~seq chunk :: acc) rest
    in
    group 1 [] msgs

type stats =
  { packets : int
  ; bytes : int
  ; seconds : float
  }

let send ?(rate = 0.) ~addr ~port packets =
  let sock = Unix.socket Unix.PF_INET Unix.SOCK_DGRAM 0 in
  Fun.protect ~finally:(fun () -> Unix.close sock) (fun () ->
    Unix.setsockopt sock Unix.SO_BROADCAST true;
    let dest = Unix.ADDR_INET (Unix.inet_addr_of_string addr, port) in
    let start = Unix.gettimeofday () in
    let bytes = ref 0 in
    List.iteri (fun k p ->
      (* Packet k is due at start + k / rate. *)
      (if rate > 0. then
         let wait = start +. (float_of_int k /. rate) -. Unix.gettimeofday () in
         if wait > 0. then Unix.sleepf wait);
      let n = Bytes.length p in
      let sent = Unix.sendto sock p 0 n [] dest in
      if sent <> n then failwith (Printf.sprintf "packet %d: sent %d of %d bytes" k sent n);
      bytes := !bytes + n)
      packets;
    { packets = List.length packets; bytes = !bytes; seconds = Unix.gettimeofday () -. start })
