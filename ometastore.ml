(* Copyright (C) 2008 Mauricio Fernandez <mfp@acm.org> http//eigenclass.org
 * See README.txt and LICENSE for the redistribution and modification terms *)

open Printf
open Unix
open Folddir
open Util
open FileUtil

let debug = ref false
let verbose = ref false
let use_mtime = ref false
let use_xattrs = ref false
let magic = "Ometastore"
let version = "1.1.0"

type xattr = { name : string; value : string }

type entry = {
  path : string;
  owner : string;
  group : string;
  mode : int;
  mtime : float;
  kind : Unix.file_kind;
  xattrs : xattr list;
}

type whatsnew = Added of entry | Deleted of entry | Diff of entry * entry

external utime : string -> nativeint -> unit = "perform_utime"
external llistxattr : string -> string list = "perform_llistxattr"
external lgetxattr : string -> string -> string = "perform_lgetxattr"
external lsetxattr : string -> string -> string -> unit = "perform_lsetxattr"
external lremovexattr : string -> string -> unit = "perform_lremovexattr"

let user_name =
  memoized
    (fun uid ->
       try
         (getpwuid uid).pw_name
       with Not_found ->
         try
           (getpwuid (getuid ())).pw_name
         with Not_found -> Sys.getenv("USER"))

let group_name =
  memoized
    (fun gid ->
       try
         (getgrgid gid).gr_name
       with Not_found ->
         try
           (getgrgid (getgid ())).gr_name
         with Not_found -> Sys.getenv("USER"))

let int_of_file_kind = function
    S_REG -> 0 | S_DIR -> 1 | S_CHR -> 2 | S_BLK -> 3 | S_LNK -> 4 | S_FIFO -> 5
  | S_SOCK -> 6

let kind_of_int = function
    0 -> S_REG | 1 -> S_DIR | 2 -> S_CHR | 3 -> S_BLK | 4 -> S_LNK | 5 -> S_FIFO
  | 6 -> S_SOCK | _ -> invalid_arg "kind_of_int"

let entry_of_path path =
  let s = lstat path in
  let user = user_name s.st_uid in
  let group = group_name s.st_gid in
  let xattrs =
    List.map
      (fun attr -> { name = attr; value = lgetxattr path attr; })
      (List.sort compare (llistxattr path))
  in
    { path = path; owner = user; group = group; mode = s.st_perm;
      kind = s.st_kind; mtime = s.st_mtime; xattrs = xattrs }

module Entries(F : Folddir.S) =
struct
  let get_entries ?(debug=false) ?(sorted=false) path =
    let aux l name stat =
      let fullname = join path name in
      let entry = { (entry_of_path fullname) with path = name } in
        match stat.st_kind with
          | S_DIR -> begin
              try access (join fullname ".git") [F_OK]; Prune (entry :: l)
              with Unix_error _ -> Continue (entry :: l)
            end
          | _ -> Continue (entry :: l)
    in List.rev (F.fold_directory ~debug ~sorted aux [] path "")
end

let write_int os bytes n =
  for i = bytes - 1 downto 0 do
    output_char os (Char.chr ((n lsr (i lsl 3)) land 0xFF))
  done

let read_int is bytes =
  let r = ref 0 in
  for i = 0 to bytes - 1 do
    r := !r lsl 8 + Char.code (input_char is)
  done;
  !r

let write_xstring os s =
  write_int os 4 (String.length s);
  output_string os s

let read_xstring is =
  let len = read_int is 4 in
  let s = String.create len in
    really_input is s 0 len;
    s

let common_prefix_chars s1 s2 =
  let rec loop s1 s2 i max =
    if s1.[i] = s2.[i] then
      if i < max then loop s1 s2 (i+1) max else i + 1
    else i
  in
    if String.length s1 = 0 || String.length s2 = 0 then 0
    else loop s1 s2 0 (min (String.length s1 - 1) (String.length s2 -1))

let dump_entries ?(verbose=false) ?(sorted=false) l fname =
  let dump_entry os prev e =
    if verbose then printf "%s\n" e.path;
    let pref = common_prefix_chars prev e.path in
    write_int os 2 pref;
    write_xstring os (String.sub e.path pref (String.length e.path - pref));
    write_xstring os e.owner;
    write_xstring os e.group;
    write_xstring os (string_of_float e.mtime);
    write_int os 2 e.mode;
    write_int os 1 (int_of_file_kind e.kind);
    write_int os 2 (List.length e.xattrs);
    List.iter
      (fun t -> write_xstring os t.name; write_xstring os t.value)
      e.xattrs;
    e.path
  in do_finally (open_out_bin fname) close_out begin fun os ->
    output_string os (magic ^ "\n");
    output_string os (version ^ "\n");
    let l = if sorted then List.sort compare l else l in
      ignore (List.fold_left (dump_entry os) "" l)
  end

let read_entries fname =
  let read_entry is prev =
    let pref = read_int is 2 in
    let path = String.sub prev 0 pref ^ read_xstring is in
    let owner = read_xstring is in
    let group = read_xstring is in
    let mtime = float_of_string (read_xstring is) in
    let mode = read_int is 2 in
    let kind = kind_of_int (read_int is 1) in
    let nattrs = read_int is 2 in
    let attrs = ref [] in
      for i = 1 to nattrs do
        let name = read_xstring is in
        let value = read_xstring is in
          attrs := { name = name; value = value } :: !attrs
      done;
      { path = path; owner = owner; group = group; mtime = mtime; mode = mode;
        kind = kind; xattrs = List.rev !attrs }
  in do_finally (open_in_bin fname) close_in begin fun is ->
    if magic <> input_line is then failwith "Invalid file: bad magic";
    let _ = input_line is (* version *) in
    let entries = ref [] in
    let prev = ref "" in
      try
        while true do
          let e = read_entry is !prev in
            entries := e :: !entries;
            prev := e.path
        done;
        assert false
      with End_of_file -> !entries
  end

module SMap = Map.Make(struct type t = string let compare = compare end)

let compare_entries l1 l2 =
  let to_map l = List.fold_left (fun m e -> SMap.add e.path e m) SMap.empty l in
  let m1 = to_map l1 in
  let m2 = to_map l2 in
  let changes =
    List.fold_left
      (fun changes e2 ->
         try
           let e1 = SMap.find e2.path m1 in
             if e1 = e2 then changes else Diff (e1, e2) :: changes
         with Not_found -> Added e2 :: changes)
      [] l2 in
  let deletions =
    List.fold_left
      (fun dels e1 -> if SMap.mem e1.path m2 then dels else Deleted e1 :: dels)
      [] l1
  in List.rev (List.rev_append deletions changes)

let print_changes ?(sorted=false) l =
  List.iter
    (function
         Added e -> printf "Added: %s\n" e.path
       | Deleted e -> printf "Deleted: %s\n" e.path
       | Diff (e1, e2) ->
           let test name f s = if f e1 <> f e2 then name :: s else s in
           let (++) x f = f x in
           let diffs =
             test "owner" (fun x -> x.owner) [] ++
             test "group" (fun x -> x.group) ++
             test "mode" (fun x -> x.mode) ++
             test "kind" (fun x -> x.kind) ++
             test "mtime"
               (if !use_mtime then (fun x -> x.mtime) else (fun _ -> 0.)) ++
             test "xattr"
               (if !use_xattrs then (fun x -> x.xattrs) else (fun _ -> []))
           in match List.rev diffs with
               [] -> ()
             | l -> printf "Changed %s: %s\n" e1.path (String.concat " " l))
    (if sorted then List.sort compare l else l)

let print_deleted ?(sorted=false) separator l =
  List.iter
    (function Deleted e -> printf "%s%s" e.path separator
       | Added _ | Diff _ -> ())
    (if sorted then List.sort compare l else l)


let out s = if !verbose then Printf.fprintf Pervasives.stdout s
            else Printf.ifprintf Pervasives.stdout s

let fix_usergroup e =
  try
    out "%s: set owner/group to %S %S\n" e.path e.owner e.group;
    chown e.path (getpwnam e.owner).pw_uid (getgrnam e.group).gr_gid;
  with Unix_error _ -> ( out "chown failed: %s\n" e.path )

let fix_xattrs src dst =
  out "%s: fixing xattrs (" src.path;
  let to_map l =
    List.fold_left (fun m e -> SMap.add e.name e.value m) SMap.empty l in
  let set_attr name value =
    out "+%S, " name;
    try lsetxattr src.path name value with Failure _ -> () in
  let del_attr name =
    out "-%S, " name;
    try lremovexattr src.path name with Failure _ -> () in
  let src = to_map src.xattrs in
  let dst = to_map dst.xattrs in
    SMap.iter
      (fun name value ->
         try
           if SMap.find name dst <> SMap.find name src then set_attr name value
         with Not_found -> set_attr name value)
      dst;
    (* remove deleted xattrs *)
    SMap.iter (fun name _ -> if not (SMap.mem name dst) then del_attr name) src;
    out ")\n"

let apply_change = function
  | Added e when e.kind = S_DIR ->
      out "%s: mkdir (mode %04o)\n" e.path e.mode;
      mkdir ~parent:true e.path;
      chmod e.path e.mode;
      fix_usergroup e
  | Deleted _ | Added _ -> ()
  | Diff (e1, e2) ->
      if e1.owner <> e2.owner || e1.group <> e2.group then fix_usergroup e2;
      if e1.mode <> e2.mode then begin
        out "%s: chmod %04o\n" e2.path e2.mode;
        chmod e2.path e2.mode;
      end;
      if e1.kind <> e2.kind then
        printf "%s: file type of changed (nothing done)\n" e1.path;
      if !use_mtime && e1.mtime <> e2.mtime then begin
        out "%s: mtime set to %.0f\n" e1.path e2.mtime;
        try 
          utime e2.path (Nativeint.of_float e2.mtime)
        with Failure _ -> ( out "utime failed: %s\n" e1.path )
      end;
      if !use_xattrs && e1.xattrs <> e2.xattrs then fix_xattrs e1 e2

let apply_changes path l =
  List.iter apply_change
    (List.rev
        (List.rev_map
           (function
                Added _ | Deleted _ as x -> x
              | Diff (e1, e2) -> Diff ({ e1 with path = join path e1.path},
                                       { e2 with path = join path e2.path}))
           l)
    )

module Allentries = Entries(Folddir.Make(Folddir.Ignore_none))
module Gitignored = Entries(Folddir.Make(Folddir.Gitignore))

let main () =
  let usage =
    "Usage: ometastore COMMAND [options]\n\
     where COMMAND is -c, -d, -s or -a.\n" in
  let mode = ref `Unset in
  let file = ref ".ometastore" in
  let path = ref "." in
  let get_entries = ref Allentries.get_entries in
  let sep = ref "\n" in
  let sorted = ref false in
  let specs = [
       "-c", Arg.Unit (fun () -> mode := `Compare),
       "show all differences between stored and real metadata";
       "-d", Arg.Unit (fun () -> mode := `Show_deleted),
       "show only files deleted or newly ignored";
       "-s", Arg.Unit (fun () -> mode := `Save), "save metadata";
       "-a", Arg.Unit (fun () -> mode := `Apply), "apply current metadata";
       "-i", Arg.Unit (fun () -> get_entries := Gitignored.get_entries),
       "mimic git semantics (honor .gitignore, don't scan git submodules)";
       "-m", Arg.Set use_mtime, "consider mtime for diff and apply";
       "-x", Arg.Set use_xattrs, "consider extended attributes for diff and apply";
       "-z", Arg.Unit (fun () -> sep := "\000"), "use \\0 to separate filenames";
       "--sort", Arg.Set sorted, "sort output by filename";
       "-v", Arg.Set verbose, "verbose mode";
       "--debug", Arg.Set debug, "debug mode";
       "--version",
         Arg.Unit (fun () -> printf "ometastore version %s\n" version; exit 0),
         "show version info";
     ]
  in Arg.parse specs ignore usage;
     match !mode with
       | `Unset -> Arg.usage specs usage
       | `Save ->
           dump_entries ~sorted:!sorted ~verbose:!verbose (!get_entries !path) !file
       | `Show_deleted | `Compare | `Apply as mode ->
           let stored = read_entries !file in
           let actual = !get_entries ~debug:!debug !path in
             match mode with
                 `Compare ->
                   print_changes ~sorted:!sorted (compare_entries stored actual)
               | `Apply -> apply_changes !path (compare_entries actual stored)
               | `Show_deleted ->
                   print_deleted ~sorted:!sorted !sep (compare_entries stored actual)

let () = main ()
