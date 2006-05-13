(* $Id$ *)

open Printf

type level =
    [ `Emerg | `Alert | `Crit | `Err | `Warning | `Notice | `Info | `Debug ]

let level_weight =
  function
    | `Emerg   -> 0
    | `Alert   -> 1
    | `Crit    -> 2
    | `Err     -> 3
    | `Warning -> 4
    | `Notice  -> 5
    | `Info    -> 6
    | `Debug   -> 7

let level_names =
  [| "emerg"; "alert"; "crit"; "err"; "warning"; "notice"; "info"; "debug" |]

class type logger =
object
  method log : component:string -> level:level -> message:string -> unit
  method reopen : unit -> unit
  method max_level : level
  method set_max_level : level -> unit
end


class channel_logger out : logger =
object(self)
  val mutable max_level = `Info

  method log ~component ~level ~message =
    let w = level_weight level in
    if w <= level_weight max_level then (
      try
	fprintf out "[%s] [%s] [%s] %s\n%!"
	  (Netdate.format "%c" (Netdate.create
				  ~zone:(Netdate.localzone)
				  (Unix.time())))
	  component
	  level_names.(w)
	  message
      with
	| error ->
	    prerr_endline ("Netplex Catastrophic Error: Unable to write to log channel: " ^ Printexc.to_string error)
    )


  method reopen() = ()

  method max_level = max_level

  method set_max_level l = max_level <- l

end

let channel_logger ch = new channel_logger ch


class file_logger file : logger =
object(self)
  val mutable out = 
    open_out_gen [ Open_wronly; Open_append; Open_creat ] 0o666 file

  val mutable max_level = `Info

  method log ~component ~level ~message =
    let w = level_weight level in
    if w <= level_weight max_level then (
      try
	fprintf out "[%s] [%s] [%s] %s\n%!"
	  (Netdate.format "%c" (Netdate.create
				  ~zone:(Netdate.localzone)
				  (Unix.time())))
	  component
	  level_names.(w)
	  message
      with
	| error ->
	    prerr_endline ("Netplex Catastrophic Error: Unable to write to log file " ^ file ^ ": " ^ Printexc.to_string error)
    )


  method reopen() =
    close_out out;
    try
      out <-
	open_out_gen [ Open_wronly; Open_append; Open_creat ] 0o666 file
    with
      | error ->
	  prerr_endline ("Netplex Catastrophic Error: Unable to reopen log file " ^ file ^ ": " ^ Printexc.to_string error)


  method max_level = max_level

  method set_max_level l = max_level <- l

end

let file_logger name = new file_logger name


class type multi_file_config =
object
  method log_directory : string
  method log_files :
    (string * [ level | `All ] * string) list
end


let no_duplicates l =
  let h = Hashtbl.create 10 in
  List.filter
    (fun p ->
       not(Hashtbl.mem h p) && (
         Hashtbl.add h p ();
         true))
    l
;;


let ast_re = Pcre.regexp "[*]";;

let regexp_of_pattern s =
  let l = Netstring_pcre.split_delim ast_re s in
  Netstring_pcre.regexp
    (String.concat ".*" (List.map (fun u -> Netstring_pcre.quote u) l) ^ "$")


class multi_file_logger (mfc : multi_file_config) : logger =
  let log_files =
    List.map
      (fun (pat, level, file) ->
	 let re = regexp_of_pattern pat in
	 (re, level, file)
      )
      mfc#log_files in
object(self)
  val channels = Hashtbl.create 10
    (* Maps files to channels *)

  val mutable max_level = `Info

  method log ~component ~level ~message =
    let w = level_weight level in
    if w <= level_weight max_level then (
      let files =
	List.map
	  (fun (_, _, file) -> file)
	  (List.filter
	     (fun (re, level_pat, _) ->
		match Netstring_pcre.string_match re component 0 with
		  | Some _ ->
		      ( match level_pat with
			  | `All -> true
			  | #level as l ->
			      w <= level_weight l
		      )
		  | None -> false
	     )
	     log_files
	  ) in
      let files = no_duplicates files in
      List.iter
	(fun file ->
	   let full_path =
	     if file <> "/" && file.[0] = '/' then
	       file
	     else
	       Filename.concat mfc#log_directory file
	   in
	   try
	     let ch = 
	       try
		 Hashtbl.find channels full_path
	       with
		 | Not_found ->
		     let ch =
	               open_out_gen 
			 [ Open_wronly; Open_append; Open_creat ] 0o666 file in
		     Hashtbl.add channels full_path ch;
		     ch
	     in
	     fprintf ch "[%s] [%s] [%s] %s\n%!"
	       (Netdate.format "%c" (Netdate.create
				       ~zone:(Netdate.localzone)
				       (Unix.time())))
	       component
	       level_names.(w)
	       message
	   with
	     | error ->
		 prerr_endline ("Netplex Catastrophic Error: Unable to write to log file " ^ full_path ^ ": " ^ Printexc.to_string error)

	)
	files
    )

  method reopen() =
    Hashtbl.iter
      (fun name ch ->
	 close_out ch)
      channels;
    Hashtbl.clear channels

  method max_level = max_level

  method set_max_level l = max_level <- l

end


let multi_file_logger mfc = new multi_file_logger mfc