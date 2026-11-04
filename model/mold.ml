let header_len = 20
let max_udp_payload = 1500 - 20 - 8
let default_session = "FH00000001"
let end_of_session_count = 0xFFFF

type packet =
  { session : string
  ; seq : int
  ; count : int
  ; messages : bytes list
  }

let header ~session ~seq ~count =
  if String.length session <> 10 then invalid_arg "Mold: session must be 10 characters";
  let b = Bytes.create header_len in
  Bytes.blit_string session 0 b 0 10;
  Bytes.set_int64_be b 10 (Int64.of_int seq);
  Bytes.set_uint16_be b 18 count;
  b

let encode ?(session = default_session) ~seq messages =
  let count = List.length messages in
  if count >= end_of_session_count then invalid_arg "Mold: too many messages";
  List.iter
    (fun m -> if Bytes.length m > 0xFFFF then invalid_arg "Mold: message too long")
    messages;
  (* Itch.frame adds exactly the 2-byte length MoldUDP64 uses. *)
  Bytes.concat Bytes.empty (header ~session ~seq ~count :: List.map Itch.frame messages)

let heartbeat ?(session = default_session) ~seq () = header ~session ~seq ~count:0

let end_of_session ?(session = default_session) ~seq () =
  header ~session ~seq ~count:end_of_session_count

let decode b =
  if Bytes.length b < header_len then Error "packet shorter than 20-byte header"
  else
    let session = Bytes.sub_string b 0 10 in
    let seq = Int64.to_int (Bytes.get_int64_be b 10) in
    let count = Bytes.get_uint16_be b 18 in
    let body = Bytes.sub b header_len (Bytes.length b - header_len) in
    if count = 0 || count = end_of_session_count then
      if Bytes.length body = 0 then Ok { session; seq; count; messages = [] }
      else Error "heartbeat / end-of-session packet has a body"
    else
      match Itch.unframe_all body with
      | Error e -> Error e
      | Ok messages when List.length messages <> count ->
        Error
          (Printf.sprintf "header says %d messages, block has %d" count
             (List.length messages))
      | Ok messages -> Ok { session; seq; count; messages }

let packetize ?(session = default_session) ?(first_seq = 1)
    ?(max_payload = max_udp_payload) messages =
  let flush seq acc packets =
    match acc with
    | [] -> packets
    | _ -> encode ~session ~seq (List.rev acc) :: packets
  in
  (* [seq]: sequence number of the first message in [acc];
     [size]: bytes the packet would have if sent now. *)
  let rec go seq size acc n packets = function
    | [] -> List.rev (flush seq acc packets)
    | m :: rest ->
      let need = 2 + Bytes.length m in
      if header_len + need > max_payload then
        invalid_arg "Mold.packetize: message doesn't fit in one packet"
      else if size + need > max_payload then
        (* packet full: send it, start a new one with this message *)
        go (seq + n) (header_len + need) [ m ] 1 (flush seq acc packets) rest
      else go seq (size + need) (m :: acc) (n + 1) packets rest
  in
  go first_seq header_len [] 0 [] messages
