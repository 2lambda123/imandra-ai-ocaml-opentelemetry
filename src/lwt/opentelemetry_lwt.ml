open Opentelemetry
open Lwt.Syntax
module Span_id = Span_id
module Trace_id = Trace_id
module Event = Event
module Span = Span
module Span_link = Span_link
module Globals = Globals
module Timestamp_ns = Timestamp_ns
module GC_metrics = GC_metrics
module Metrics_callbacks = Metrics_callbacks
module Trace_context = Trace_context

module Trace = struct
  open Proto.Trace
  include Trace

  (** Sync span guard *)
  let with_ ?trace_state ?service_name ?(attrs = []) ?kind ?trace_id ?parent
      ?scope ?links name (f : Scope.t -> 'a Lwt.t) : 'a Lwt.t =
    let trace_id =
      match trace_id, scope with
      | Some trace_id, _ -> trace_id
      | None, Some scope -> scope.trace_id
      | None, None -> Trace_id.create ()
    in
    let parent =
      match parent, scope with
      | Some span_id, _ -> Some span_id
      | None, Some scope -> Some scope.span_id
      | None, None -> None
    in
    let start_time = Timestamp_ns.now_unix_ns () in
    let span_id = Span_id.create () in
    let scope = { trace_id; span_id; events = []; attrs } in
    let finally ok =
      let status =
        match ok with
        | Ok () -> default_status ~code:Status_code_ok ()
        | Error e -> default_status ~code:Status_code_error ~message:e ()
      in
      let span, _ =
        Span.create ?kind ~trace_id ?parent ?links ~id:span_id ?trace_state
          ~attrs:scope.attrs ~events:scope.events ~start_time
          ~end_time:(Timestamp_ns.now_unix_ns ())
          ~status name
      in
      emit ?service_name [ span ]
    in
    try%lwt
      let* x = f scope in
      let () = finally (Ok ()) in
      Lwt.return x
    with e ->
      let () = finally (Error (Printexc.to_string e)) in
      Lwt.fail e
end

module Metrics = struct
  include Metrics
end

module Logs = struct
  include Proto.Logs
  include Logs
end
