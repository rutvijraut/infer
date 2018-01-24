(*
 * Copyright (c) 2009 - 2013 Monoidics ltd.
 * Copyright (c) 2013 - present Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 *)

open! IStd
open! PVariant
module Hashtbl = Caml.Hashtbl

(** Support for Execution environments *)

module L = Logging
module F = Format

(** per-file data: type environment and cfg *)
type file_data =
  { source: SourceFile.t
  ; tenv_file: DB.filename
  ; mutable tenv: Tenv.t option
  ; mutable cfg: Cfg.t option }

(** get the path to the tenv file, which either one tenv file per source file or a global tenv file *)
let tenv_of_source source =
  let source_dir = DB.source_dir_from_source_file source in
  let per_source_tenv_filename = DB.source_dir_get_internal_file source_dir ".tenv" in
  if Sys.file_exists (DB.filename_to_string per_source_tenv_filename) = `Yes then
    per_source_tenv_filename
  else DB.global_tenv_fname


(** create a new file_data *)
let new_file_data source =
  let tenv_file = tenv_of_source source in
  (* Do not fill in tenv and cfg as they can be quite large. This makes calls to fork() cheaper
     until we start filling out these fields. *)
  { source
  ; tenv_file
  ; tenv= None (* Sil.load_tenv_from_file tenv_file *)
  ; cfg= None (* Cfg.load_cfg_from_file cfg_file *) }


let create_file_data table source =
  match SourceFile.Hash.find table source with
  | file_data ->
      file_data
  | exception Not_found ->
      let file_data = new_file_data source in
      SourceFile.Hash.add table source file_data ;
      file_data


type t =
  { proc_map: file_data Typ.Procname.Hash.t  (** map from procedure name to file data *)
  ; file_map: file_data SourceFile.Hash.t  (** map from source files to file data *)
  ; source_file: SourceFile.t  (** source file being analyzed *) }

let get_file_data exe_env pname =
  try Some (Typ.Procname.Hash.find exe_env.proc_map pname) with Not_found ->
    let source_file_opt =
      match Attributes.load pname with
      | None ->
          L.(debug Analysis Medium) "can't find tenv_cfg_object for %a@." Typ.Procname.pp pname ;
          None
      | Some proc_attributes when Config.reactive_capture ->
          let get_captured_file {ProcAttributes.source_file_captured} = source_file_captured in
          OndemandCapture.try_capture proc_attributes |> Option.map ~f:get_captured_file
      | Some proc_attributes ->
          Some proc_attributes.ProcAttributes.source_file_captured
    in
    let get_file_data_for_source source_file =
      let file_data = create_file_data exe_env.file_map source_file in
      Typ.Procname.Hash.replace exe_env.proc_map pname file_data ;
      file_data
    in
    Option.map ~f:get_file_data_for_source source_file_opt


let file_data_to_tenv file_data =
  if is_none file_data.tenv then file_data.tenv <- Tenv.load_from_file file_data.tenv_file ;
  file_data.tenv


let file_data_to_cfg file_data =
  if is_none file_data.cfg then file_data.cfg <- Cfg.load file_data.source ;
  file_data.cfg


let java_global_tenv =
  lazy
    ( match Tenv.load_from_file DB.global_tenv_fname with
    | None ->
        L.(die InternalError)
          "Could not load the global tenv at path '%s'"
          (DB.filename_to_string DB.global_tenv_fname)
    | Some tenv ->
        tenv )


(** return the type environment associated to the procedure *)
let get_tenv exe_env proc_name =
  match proc_name with
  | Typ.Procname.Java _ ->
      Lazy.force java_global_tenv
  | _ ->
    match get_file_data exe_env proc_name with
    | Some file_data -> (
      match file_data_to_tenv file_data with
      | Some tenv ->
          tenv
      | None ->
          L.(die InternalError)
            "get_tenv: tenv not found for %a in file '%s'" Typ.Procname.pp proc_name
            (DB.filename_to_string file_data.tenv_file) )
    | None ->
        L.(die InternalError) "get_tenv: file_data not found for %a" Typ.Procname.pp proc_name


(** return the cfg associated to the procedure *)
let get_cfg exe_env pname =
  match get_file_data exe_env pname with
  | None ->
      None
  | Some file_data ->
      file_data_to_cfg file_data


(** return the proc desc associated to the procedure *)
let get_proc_desc exe_env pname =
  match get_cfg exe_env pname with
  | Some cfg -> (
    match Typ.Procname.Hash.find cfg pname with
    | proc_desc ->
        Some proc_desc
    | exception Not_found ->
        None )
  | None ->
      None


let mk source_file =
  {proc_map= Typ.Procname.Hash.create 17; file_map= SourceFile.Hash.create 1; source_file}


(** [iter_files f exe_env] applies [f] to the filename and tenv and cfg for each file in [exe_env] *)
let iter_files f exe_env =
  let source = exe_env.source_file in
  let cfg = Cfg.load source in
  Option.iter ~f:(f source) cfg
