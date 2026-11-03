type header =
  { stock_locate : int
  ; tracking : int
  ; timestamp_ns : int
  }

let default_header = { stock_locate = 1; tracking = 0; timestamp_ns = 0 }
let stock = "TEST    "

let length_of_type = function
  | 'A' -> Some 36
  | 'E' -> Some 31
  | 'X' -> Some 23
  | 'D' -> Some 19
  | _ -> None

(* --- big-endian helpers ------------------------------------------------ *)

let set_u16 b off v = Bytes.set_uint16_be b off (v land 0xFFFF)
let set_u32 b off v = Bytes.set_int32_be b off (Int32.of_int (v land 0xFFFF_FFFF))
let set_u64 b off v = Bytes.set_int64_be b off (Int64.of_int v)

let set_u48 b off v =
  for i = 0 to 5 do
    Bytes.set_uint8 b (off + i) ((v lsr (8 * (5 - i))) land 0xFF)
  done

let get_u16 b off = Bytes.get_uint16_be b off
let get_u32 b off = Int32.to_int (Bytes.get_int32_be b off) land 0xFFFF_FFFF
let get_u64 b off = Int64.to_int (Bytes.get_int64_be b off)

(* --- encode ------------------------------------------------------------- *)

let write_header b typ (h : header) =
  Bytes.set b 0 typ;
  set_u16 b 1 h.stock_locate;
  set_u16 b 3 h.tracking;
  set_u48 b 5 h.timestamp_ns

let encode ?(header = default_header) ?(match_number = 0) (msg : Msg.t) =
  match msg with
  | Add { id; side; price; qty } ->
    let b = Bytes.create 36 in
    write_header b 'A' header;
    set_u64 b 11 id;
    Bytes.set b 19 (match side with Buy -> 'B' | Sell -> 'S');
    set_u32 b 20 qty;
    Bytes.blit_string stock 0 b 24 8;
    set_u32 b 32 price;
    b
  | Executed { id; qty } ->
    let b = Bytes.create 31 in
    write_header b 'E' header;
    set_u64 b 11 id;
    set_u32 b 19 qty;
    set_u64 b 23 match_number;
    b
  | Cancel { id; qty } ->
    let b = Bytes.create 23 in
    write_header b 'X' header;
    set_u64 b 11 id;
    set_u32 b 19 qty;
    b
  | Delete { id } ->
    let b = Bytes.create 19 in
    write_header b 'D' header;
    set_u64 b 11 id;
    b

(* --- decode ------------------------------------------------------------- *)

let decode b =
  if Bytes.length b = 0 then Error "empty message"
  else
    let typ = Bytes.get b 0 in
    match length_of_type typ with
    | None -> Error (Printf.sprintf "unsupported message type %C" typ)
    | Some n when Bytes.length b <> n ->
      Error (Printf.sprintf "type %C: expected %d bytes, got %d" typ n (Bytes.length b))
    | Some _ ->
      let id = get_u64 b 11 in
      (match typ with
       | 'A' ->
         (match Bytes.get b 19 with
          | ('B' | 'S') as s ->
            Ok
              (Msg.Add
                 { id
                 ; side = (if s = 'B' then Buy else Sell)
                 ; qty = get_u32 b 20
                 ; price = get_u32 b 32
                 })
          | c -> Error (Printf.sprintf "bad side byte %C" c))
       | 'E' -> Ok (Msg.Executed { id; qty = get_u32 b 19 })
       | 'X' -> Ok (Msg.Cancel { id; qty = get_u32 b 19 })
       | 'D' -> Ok (Msg.Delete { id })
       | _ -> assert false)

(* --- framing ------------------------------------------------------------ *)

let frame m =
  let n = Bytes.length m in
  let b = Bytes.create (n + 2) in
  set_u16 b 0 n;
  Bytes.blit m 0 b 2 n;
  b

let unframe_all buf =
  let total = Bytes.length buf in
  let rec go pos acc =
    if pos = total then Ok (List.rev acc)
    else if pos + 2 > total then Error "truncated length prefix"
    else
      let n = get_u16 buf pos in
      if pos + 2 + n > total then Error "truncated message"
      else go (pos + 2 + n) (Bytes.sub buf (pos + 2) n :: acc)
  in
  go 0 []

let to_hex b =
  String.concat " "
    (List.init (Bytes.length b) (fun i -> Printf.sprintf "%02x" (Bytes.get_uint8 b i)))
