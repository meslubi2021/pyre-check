(*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

(* TODO(T132410158) Add a module-level doc comment. *)

open Core
open Pyre
module SharedMemory = Hack_parallel.Std.SharedMemory

type t = {
  root: ErrorsEnvironment.t;
  overlays: ErrorsEnvironment.Overlay.t String.Table.t;
}

type overlay_identifier = string

let create root = { root; overlays = String.Table.create () }

let root { root; _ } = ErrorsEnvironment.read_only root

let overlay { overlays; _ } identifier =
  String.Table.find overlays identifier >>| ErrorsEnvironment.Overlay.read_only


let get_or_create_overlay { root; overlays } identifier =
  match String.Table.find overlays identifier with
  | Some overlay -> overlay
  | None ->
      let new_overlay = ErrorsEnvironment.read_only root |> ErrorsEnvironment.Overlay.create in
      let () = String.Table.add overlays ~key:identifier ~data:new_overlay |> ignore in
      new_overlay


let remove_overlay { overlays; _ } identifier =
  (* NOTE(grievejia): This is going to leak some sharedmem *)
  String.Table.remove overlays identifier


let controls { root; _ } = ErrorsEnvironment.read_only root |> ErrorsEnvironment.ReadOnly.controls

let configuration environment = controls environment |> EnvironmentControls.configuration

let root_errors { root; _ } =
  ErrorsEnvironment.read_only root |> ErrorsEnvironment.ReadOnly.get_all_errors


let overlay_errors environment identifier =
  overlay environment identifier
  >>| ErrorsEnvironment.ReadOnly.get_all_errors
  |> Option.value ~default:[]


let load controls = ErrorsEnvironment.load controls |> create

let store { root; _ } = ErrorsEnvironment.store root

(* TODO (T124332093): To make overlays consistent, we need to propagate parent environment updates.
   This is deferred until we can get overlays working end-to-end *)

let prepare_for_update overlaid_environment ~scheduler =
  let configuration = configuration overlaid_environment in
  Scheduler.once_per_worker scheduler ~configuration ~f:SharedMemory.invalidate_caches;
  SharedMemory.invalidate_caches ();
  SharedMemory.collect `aggressive;
  ()


let update_root { root; _ } = ErrorsEnvironment.update_this_and_all_preceding_environments root

let update_overlay_with_code environment ~code_updates identifier =
  get_or_create_overlay environment identifier
  |> ErrorsEnvironment.Overlay.update_overlaid_code ~code_updates


module UpdateType = struct
  type t =
    | Root
    | Overlay

  let event_name = function
    | Root -> "incremental check"
    | Overlay -> "overlay recheck"
end

let log_update_stats update_type ~timer ~updated_paths_count ~update_result =
  Statistics.event
    ~section:`Memory
    ~name:"shared memory size"
    ~integers:["size", Memory.heap_size ()]
    ();
  let {
    ErrorsEnvironment.UpdateStatistics.module_updates_count;
    invalidated_modules_count;
    rechecked_functions_count;
    rechecked_modules_count;
  }
    =
    ErrorsEnvironment.UpdateStatistics.count_updates update_result
  in
  Statistics.performance
    ~name:(UpdateType.event_name update_type)
    ~timer
    ~integers:
      [
        "number of changed files", updated_paths_count;
        "number of module tracker updates", module_updates_count;
        "number of parser updates", invalidated_modules_count;
        "number of rechecked modules", rechecked_modules_count;
        "number of re-checked functions", rechecked_functions_count;
      ]
    ();
  ()


let run_update_root ({ overlays; _ } as overlaid_environment) ~scheduler events =
  let timer = Timer.start () in
  prepare_for_update overlaid_environment ~scheduler;
  (* Repopulate the environment. *)
  Log.info "Repopulating the environment...";
  let updated_paths_count = List.length events in
  let update_result = update_root overlaid_environment ~scheduler events in
  String.Table.iter overlays ~f:(fun overlay ->
      ErrorsEnvironment.Overlay.propagate_parent_update overlay update_result |> ignore);
  (* Log updates *)
  log_update_stats UpdateType.Root ~timer ~update_result ~updated_paths_count


let run_update_overlay_with_code overlaid_environment ~code_updates identifier =
  let timer = Timer.start () in
  SharedMemory.invalidate_caches ();
  (* Repopulate the environment. *)
  Log.info "Repopulating overlay environment...";
  let updated_paths_count = List.length code_updates in
  let update_result = update_overlay_with_code overlaid_environment identifier ~code_updates in
  (* Log updates *)
  log_update_stats UpdateType.Overlay ~timer ~update_result ~updated_paths_count
