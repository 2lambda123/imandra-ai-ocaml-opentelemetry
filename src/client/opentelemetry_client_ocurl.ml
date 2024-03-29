
(*
   https://github.com/open-telemetry/oteps/blob/main/text/0035-opentelemetry-protocol.md
   https://github.com/open-telemetry/oteps/blob/main/text/0099-otlp-http.md
 *)

(* TODO *)

module OT = Opentelemetry
open Opentelemetry

let[@inline] (let@) f x = f x

let debug_ = ref (try bool_of_string @@ Sys.getenv "DEBUG" with _ -> false)

let default_url = "http://localhost:4318"
let url = ref (try Sys.getenv "OTEL_EXPORTER_OTLP_ENDPOINT" with _ -> default_url)
let get_url () = !url
let set_url s = url := s

let lock_ : (unit -> unit) ref = ref ignore
let unlock_ : (unit -> unit) ref = ref ignore
let set_mutex ~lock ~unlock : unit =
  lock_ := lock;
  unlock_ := unlock

let container_id_ = ref None

(** Read the container ID from [/proc/self/cgroup], if it exists, and send it in the [Datadog-Container-ID] HTTP header.

    Datadog uses this add container information to traces.

    See https://github.com/DataDog/dd-trace-js/blob/253fce6fceaf776b14b10f19be586b961cbb66ec/packages/dd-trace/src/exporters/agent/docker.js#L5-L8
 *)
let read_container_id_ =
  let proc_self_cgroup = "/proc/self/cgroup" in
  let uuid_source = "[0-9a-f]{8}[-_][0-9a-f]{4}[-_][0-9a-f]{4}[-_][0-9a-f]{4}[-_][0-9a-f]{12}" in
  let container_source = "[0-9a-f]{64}" in
  let task_source = "[0-9a-f]{32}-\\d+" in
  let re =
    Re.Pcre.re ~flags:[`MULTILINE]
      (Printf.sprintf {|.*(%s|%s|%s)(?:\.scope)?$|} uuid_source container_source task_source)
    |> Re.compile in
  fun () ->
  match open_in proc_self_cgroup  with
  | ic ->
     Fun.protect ~finally:(fun () -> close_in_noerr ic) (fun () ->
         match input_line ic with
         | exception End_of_file -> None
         | line ->
            match Re.exec_opt re line with
            | None -> None
            | Some groups ->
               let c_id = Re.Group.get groups 1 in
               if !debug_ then Printf.eprintf "read container id %S from %s\n%!" c_id proc_self_cgroup;
               Some c_id
       )
  | exception _ -> None


module Config = struct
  type t = {
    debug: bool;
    url: string;
    batch_traces: int option;
    batch_metrics: int option;
    batch_timeout_ms: int;
    thread: bool;
  }

  let pp out self =
    let ppiopt = Format.pp_print_option Format.pp_print_int in
    let {debug; url; batch_traces; batch_metrics;
         batch_timeout_ms; thread} = self in
    Format.fprintf out "{@[ debug=%B;@ url=%S;@ \
                        batch_traces=%a;@ batch_metrics=%a;@
                        batch_timeout_ms=%d; thread=%B @]}"
      debug url ppiopt batch_traces ppiopt batch_metrics
      batch_timeout_ms thread

  let make
      ?(debug= !debug_)
      ?(url= get_url())
      ?(batch_traces=Some 400)
      ?(batch_metrics=None)
      ?(batch_timeout_ms=500)
      ?(thread=true)
      () : t =
    { debug; url; batch_traces; batch_metrics; batch_timeout_ms;
      thread; }
end

(* critical section for [f()] *)
let[@inline] with_lock_ f =
  !lock_();
  Fun.protect ~finally:!unlock_ f

let[@inline] with_mutex_ m f =
  Mutex.lock m;
  Fun.protect ~finally:(fun () -> Mutex.unlock m) f

let _init_curl = lazy (
  Curl.global_init Curl.CURLINIT_GLOBALALL;
  at_exit Curl.global_cleanup;
)

type error = [
  | `Status of int * Opentelemetry.Proto.Status.status
  | `Failure of string
]

let n_errors = Atomic.make 0
let n_dropped = Atomic.make 0

let report_err_ = function
  | `Failure msg ->
    Format.eprintf "@[<2>opentelemetry: export failed: %s@]@." msg
  | `Status (code, status) ->
    Format.eprintf "@[<2>opentelemetry: export failed with@ http code=%d@ status %a@]@."
      code Proto.Status.pp_status status

module type CURL = sig
  val send : path:string -> decode:(Pbrt.Decoder.t -> 'a) -> string -> ('a, error) result
  val cleanup : unit -> unit
end

(* create a curl client *)
module Curl() : CURL = struct
  open Opentelemetry.Proto
  let() = Lazy.force _init_curl

  let buf_res = Buffer.create 256

  (* TODO: use Curl.Multi, etc. instead? *)

  (* http client *)
  let curl : Curl.t = Curl.init ()

  let cleanup () = Curl.cleanup curl

  (* TODO: use Curl multi *)

  (* send the content to the remote endpoint/path *)
  let send ~path ~decode (bod:string) : ('a, error) result =
    Curl.reset curl;
    if !debug_ then Curl.set_verbose curl true;
    Curl.set_url curl (!url ^ path);
    Curl.set_httppost curl [];
    let header = ["Content-Type: application/x-protobuf"] in
    let header =
      match !container_id_ with
      | None -> header
      | Some cid -> Printf.sprintf "Datadog-Container-ID: %s" cid :: header
    in
    Curl.set_httpheader curl header;
    (* write body *)
    Curl.set_post curl true;
    Curl.set_postfieldsize curl (String.length bod);
    Curl.set_readfunction curl
      begin
        let i = ref 0 in
        (fun n ->
           if !debug_ then Printf.eprintf "curl asks for %d bytes\n%!" n;
           let len = min n (String.length bod - !i) in
           let s = String.sub bod !i len in
           if !debug_ then Printf.eprintf "gave curl %d bytes\n%!" len;
           i := !i + len;
           s)
      end;
    (* read result's body *)
    Buffer.clear buf_res;
    Curl.set_writefunction curl
      (fun s -> Buffer.add_string buf_res s; String.length s);
    try
      match Curl.perform curl with
      | () ->
        let code = Curl.get_responsecode curl in
        if !debug_ then Printf.eprintf "result body: %S\n%!" (Buffer.contents buf_res);
        let dec = Pbrt.Decoder.of_string (Buffer.contents buf_res) in
        if code >= 200 && code < 300 then (
          let res = decode dec in
          Ok res
        ) else (
          let status = Status.decode_status dec in
          Error (`Status (code, status))
        )
      | exception Curl.CurlException (_, code, msg) ->
        let status = Status.default_status
            ~code:(Int32.of_int code) ~message:(Bytes.unsafe_of_string msg) () in
        Error(`Status (code, status))
    with e -> Error (`Failure (Printexc.to_string e))
end

module type PUSH = sig
  type elt
  val push : elt -> unit
  val is_empty : unit -> bool
  val is_big_enough : unit -> bool
  val pop_iter_all : (elt -> unit) -> unit
end

(* queue of fixed size *)
module FQueue : sig
  type 'a t
  val create : dummy:'a -> int -> 'a t
  val size : _ t -> int
  val push : 'a t -> 'a -> bool (* true iff it could write element *)
  val pop_iter_all : 'a t -> ('a -> unit) -> unit
end = struct
  type 'a t = {
    arr: 'a array;
    mutable i: int;
  }

  let create ~dummy n : _ t =
    assert (n >= 1);
    { arr=Array.make n dummy;
      i=0;
    }

  let[@inline] size self = self.i
  let[@inline] is_full self = self.i = Array.length self.arr

  let push (self:_ t) x : bool =
    if is_full self then false
    else (
      self.arr.(self.i) <- x;
      self.i <- 1 + self.i;
      true
    )

  let pop_iter_all (self: _ t) f =
    for j=0 to self.i-1 do
      f self.arr.(j)
    done;
    self.i <- 0
end

(* generate random IDs *)
module Gen_ids() = struct
  let rand_ = Random.State.make_self_init()

  let rand_bytes_8 () : bytes =
    let@() = with_lock_ in
    let b = Bytes.create 8 in
    for i=0 to 1 do
      let r = Random.State.bits rand_ in (* 30 bits, of which we use 24 *)
      Bytes.set b (i*3) (Char.chr (r land 0xff));
      Bytes.set b (i*3+1) (Char.chr (r lsr 8 land 0xff));
      Bytes.set b (i*3+2) (Char.chr (r lsr 16 land 0xff));
    done;
    let r = Random.State.bits rand_ in
    Bytes.set b 6 (Char.chr (r land 0xff));
    Bytes.set b 7 (Char.chr (r lsr 8 land 0xff));
    b

  let rand_bytes_16 () : bytes =
    let@() = with_lock_ in
    let b = Bytes.create 16 in
    for i=0 to 4 do
      let r = Random.State.bits rand_ in (* 30 bits, of which we use 24 *)
      Bytes.set b (i*3) (Char.chr (r land 0xff));
      Bytes.set b (i*3+1) (Char.chr (r lsr 8 land 0xff));
      Bytes.set b (i*3+2) (Char.chr (r lsr 16 land 0xff));
    done;
    let r = Random.State.bits rand_ in
    Bytes.set b 15 (Char.chr (r land 0xff)); (* last byte *)
    b
end

(** Callback for when an event is properly sent to the collector *)
type over_cb = unit -> unit

(** An emitter. This is used by {!Backend} below to forward traces/metrics/…
    from the program to whatever collector client we have. *)
module type EMITTER = sig
  open Opentelemetry.Proto

  val push_trace : Trace.resource_spans list -> over:over_cb -> unit
  val push_metrics : Metrics.resource_metrics list -> over:over_cb -> unit

  val cleanup : unit -> unit
end

type 'a push = (module PUSH with type elt = 'a)
type on_full_cb = (unit -> unit)

(* make a "push" object, along with a setter for a callback to call when
   it's ready to emit a batch *)
let mk_push (type a) ?batch () : (module PUSH with type elt = a) * (on_full_cb -> unit) =
  let on_full: on_full_cb ref = ref ignore in
  let push =
    match batch with
    | None ->
      let r = ref None in
      let module M = struct
        type elt = a
        let is_empty () = !r == None
        let is_big_enough () = !r != None
        let push x =
          r := Some x; !on_full()
        let pop_iter_all f = Option.iter f !r; r := None
      end in
      (module M : PUSH with type elt = a)

    | Some n ->
      let q = FQueue.create ~dummy:(Obj.magic 0) (3 * n) in
      let module M = struct
        type elt = a
        let is_empty () = FQueue.size q = 0
        let is_big_enough () = FQueue.size q >= n
        let push x =
          if not (FQueue.push q x) || FQueue.size q > n then (
            !on_full();
            if not (FQueue.push q x) then (
              Atomic.incr n_dropped; (* drop item *)
            )
          )
        let pop_iter_all f = FQueue.pop_iter_all q f
      end in
      (module M : PUSH with type elt = a)

  in
  push, ((:=) on_full)


(* make an emitter.

   exceptions inside should be caught, see
   https://opentelemetry.io/docs/reference/specification/error-handling/ *)
let mk_emitter ~(config:Config.t) () : (module EMITTER) =
  let open Proto in

  let continue = ref true in

  let ((module E_trace) : (Trace.resource_spans list * over_cb) push), on_trace_full =
    mk_push ?batch:config.batch_traces () in
  let ((module E_metrics) : (Metrics.resource_metrics list * over_cb) push), on_metrics_full =
    mk_push ?batch:config.batch_metrics () in

  let encoder = Pbrt.Encoder.create() in

  let ((module C) as curl) = (module Curl() : CURL) in

  let emit_metrics (l:(Metrics.resource_metrics list*over_cb) list) =
    Pbrt.Encoder.reset encoder;
    let resource_metrics =
      List.fold_left (fun acc (l,_) -> List.rev_append l acc) [] l in
    Metrics_service.encode_export_metrics_service_request
      (Metrics_service.default_export_metrics_service_request
         ~resource_metrics ())
      encoder;
    begin match
        C.send ~path:"/v1/metrics" ~decode:(fun _ -> ())
          (Pbrt.Encoder.to_string encoder)
      with
      | Ok () -> ()
      | Error err ->
        (* TODO: log error _via_ otel? *)
        Atomic.incr n_errors;
        report_err_ err
    end;
    (* signal completion *)
    List.iter (fun (_,over) -> over()) l;
  in

  let emit_traces (l:(Trace.resource_spans list * over_cb) list) =
    Pbrt.Encoder.reset encoder;
    let resource_spans =
      List.fold_left (fun acc (l,_) -> List.rev_append l acc) [] l in
    Trace_service.encode_export_trace_service_request
      (Trace_service.default_export_trace_service_request ~resource_spans ())
      encoder;
    begin match
        C.send ~path:"/v1/traces" ~decode:(fun _ -> ())
          (Pbrt.Encoder.to_string encoder)
      with
      | Ok () -> ()
      | Error err ->
        (* TODO: log error _via_ otel? *)
        Atomic.incr n_errors;
        report_err_ err
    end;
    (* signal completion *)
    List.iter (fun (_,over) -> over()) l;
  in

  let last_wakeup = Atomic.make (Mtime_clock.now()) in
  let timeout = Mtime.Span.(config.batch_timeout_ms * ms) in
  let batch_timeout() : bool =
    let elapsed = Mtime.span (Mtime_clock.now()) (Atomic.get last_wakeup) in
    Mtime.Span.compare elapsed timeout >= 0
  in

  let emit_metrics ?(force=false) () : bool =
    if (force && not (E_metrics.is_empty())) ||
        (not force && E_metrics.is_big_enough ()) then (
      let batch = ref [] in
      E_metrics.pop_iter_all (fun l -> batch := l :: !batch);
      emit_metrics !batch;
      Atomic.set last_wakeup (Mtime_clock.now());
      true
    ) else false
  in
  let emit_traces ?(force=false) () : bool =
    if (force && not (E_trace.is_empty())) ||
        (not force && E_trace.is_big_enough ()) then (
      let batch = ref [] in
      E_trace.pop_iter_all (fun l -> batch := l :: !batch);
      emit_traces !batch;
      Atomic.set last_wakeup (Mtime_clock.now());
      true
    ) else false
  in

  let[@inline] guard f =
    try f()
    with e ->
      Printf.eprintf "opentelemetry-curl: uncaught exception: %s\n%!"
        (Printexc.to_string e)
  in

  let emit_all_force () =
    let@ () = guard in
    ignore (emit_traces ~force:true () : bool);
    ignore (emit_metrics ~force:true () : bool);
  in


  if config.thread then (
    begin
      let m = Mutex.create() in
      set_mutex ~lock:(fun () -> Mutex.lock m) ~unlock:(fun () -> Mutex.unlock m);
    end;

    let ((module C) as curl) = (module Curl() : CURL) in

    let m = Mutex.create() in
    let cond = Condition.create() in

    let bg_thread () =
      while !continue do
        let@ () = guard in
        let timeout = batch_timeout() in
        if emit_metrics ~force:timeout () then ()
        else if emit_traces ~force:timeout () then ()
        else (
          (* wait *)
          let@ () = with_mutex_ m in
          Condition.wait cond m;
        )
      done;
      (* flush remaining events *)
      begin
        let@ () = guard in
        ignore (emit_traces ~force:true () : bool);
        ignore (emit_metrics ~force:true () : bool);
        C.cleanup();
      end
    in

    let _: Thread.t = Thread.create bg_thread () in

    let wakeup () =
      with_mutex_ m (fun () -> Condition.signal cond);
      Thread.yield()
    in

    (* wake up if a batch is full *)
    on_metrics_full wakeup;
    on_trace_full wakeup;

    let module M = struct
      let push_trace e ~over =
        E_trace.push (e,over);
        if batch_timeout() then wakeup()
      let push_metrics e ~over =
        E_metrics.push (e,over);
        if batch_timeout() then wakeup()
      let cleanup () =
        continue := false;
        with_mutex_ m (fun () -> Condition.broadcast cond)
    end in
    (module M)
  ) else (

    on_metrics_full (fun () ->
        ignore (emit_metrics () : bool));
    on_trace_full (fun () ->
        ignore (emit_traces () : bool));

    let cleanup () =
      emit_all_force();
      C.cleanup();
    in

    let module M = struct
      let push_trace e ~over =
        let@() = guard in
        E_trace.push (e,over);
        if batch_timeout() then emit_all_force()

      let push_metrics e ~over =
        let@() = guard in
        E_metrics.push (e,over);
        if batch_timeout() then emit_all_force()

      let cleanup = cleanup
    end in
    (module M)
  )

module Backend(Arg : sig val config : Config.t end)()
  : Opentelemetry.Collector.BACKEND
= struct
  include Gen_ids()

  include (val mk_emitter ~config:Arg.config ())

  open Opentelemetry.Proto
  open Opentelemetry.Collector

  let send_trace : Trace.resource_spans list sender = {
    send=fun l ~over ~ret ->
      let@() = with_lock_ in
      if !debug_ then Format.eprintf "send spans %a@." (Format.pp_print_list Trace.pp_resource_spans) l;
      push_trace l ~over;
      ret()
  }

  let last_sent_metrics = Atomic.make (Mtime_clock.now())
  let timeout_sent_metrics = Mtime.Span.(5 * s) (* send metrics from time to time *)

  let additional_metrics () : _ list =
      (* add exporter metrics to the lot? *)
      let last_emit = Atomic.get last_sent_metrics in
      let now = Mtime_clock.now() in
      let add_own_metrics =
        let elapsed = Mtime.span last_emit now in
        Mtime.Span.compare elapsed timeout_sent_metrics > 0
      in

      if add_own_metrics then (
        let open OT.Metrics in
        Atomic.set last_sent_metrics now;
        [make_resource_metrics [
            sum ~name:"otel-export.dropped" ~is_monotonic:true [
              int ~start_time_unix_nano:(Mtime.to_uint64_ns last_emit)
                ~now:(Mtime.to_uint64_ns now) (Atomic.get n_dropped);
            ];
            sum ~name:"otel-export.errors" ~is_monotonic:true [
              int ~start_time_unix_nano:(Mtime.to_uint64_ns last_emit)
                ~now:(Mtime.to_uint64_ns now) (Atomic.get n_errors);
            ];
          ]]
      ) else []

  let send_metrics : Metrics.resource_metrics list sender = {
    send=fun m ~over ~ret ->
      let@() = with_lock_ in
      if !debug_ then Format.eprintf "send metrics %a@." (Format.pp_print_list Metrics.pp_resource_metrics) m;

      let m = List.rev_append (additional_metrics()) m in
      push_metrics m ~over;
      ret()
  }
end

let setup_ ~(config:Config.t) () =
  debug_ := config.debug;
  container_id_ := read_container_id_ ();
  let module B = Backend(struct let config=config end)() in
  Opentelemetry.Collector.backend := Some (module B);
  B.cleanup

let setup ?(config=Config.make()) ?(enable=true) () =
  if enable then (
    let cleanup = setup_ ~config () in
    at_exit cleanup
  )

let with_setup ?(config=Config.make()) ?(enable=true) () f =
  if enable then (
    let cleanup = setup_ ~config () in
    Fun.protect ~finally:cleanup f
  ) else f()
