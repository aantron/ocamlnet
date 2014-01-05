(* $Id$ *)

open Printf

module type GNUTLS_PROVIDER =
  sig
    include Netsys_crypto_types.TLS_PROVIDER

    val gnutls_session : endpoint -> Nettls_gnutls_bindings.gnutls_session_t
    val gnutls_credentials : credentials -> 
                               Nettls_gnutls_bindings.gnutls_credentials
  end


module type GNUTLS_ENDPOINT =
  sig
    module TLS : GNUTLS_PROVIDER
    val endpoint : TLS.endpoint
  end


exception I of (module GNUTLS_PROVIDER)

module type SELF =
  sig
    val self : exn ref
  end


module Make_TLS_1 
         (Self:SELF)
         (Exc:Netsys_crypto_types.TLS_EXCEPTIONS) : GNUTLS_PROVIDER =
  struct
    let implementation_name = "Nettls_gnutls.TLS"
    let implementation () = !Self.self

    module Exc = Exc
    module G = Nettls_gnutls_bindings

    type credentials =
        { gcred : G.gnutls_credentials;
        }

    type dh_params =
      [ `PKCS3_PEM_file of string
      | `PKCS3_DER of string
      | `Generate of int
      ]
          
    type crt_list =
        [`PEM_file of string | `DER of string list]

    type crl_list =
        [`PEM_file of string | `DER of string list]

    type private_key =
        [ `PEM_file of string 
        | `RSA of string 
        | `DSA of string
        | `EC of string
        | `PKCS8 of string
        | `PKCS8_encrypted of string
        ]

    type server_name = [ `Domain of string ]

    type state =
        [ `Start | `Handshake | `Data_rw | `Data_r | `Data_w | `Data_rs
        | `Switching | `Accepting | `Refusing | `End
        ]

    type raw_credentials =
      [ `X509 of string
      | `Anonymous
      ]

    type role = [ `Server | `Client ]

    type endpoint =
        { role : role;
          recv : (Netsys_types.memory -> int);
          send : (Netsys_types.memory -> int -> int);
          mutable config : config;
          session : G.gnutls_session_t;
          peer_name : string option;
          mutable our_cert : raw_credentials option;
          mutable state : state;
          mutable trans_eof : bool;
        }

      and config =
        { priority : G.gnutls_priority_t;
          dh_params : G.gnutls_dh_params_t option;
          peer_auth : [ `None | `Optional | `Required ];
          credentials : credentials;
          verify : endpoint -> bool;
          peer_name_unchecked : bool;
        }

    type serialized_session =
        { ser_data : string;    (* GnuTLS packed session *)
          ser_our_cert : raw_credentials option;
        }

    let error_message code = 
      match code with
        | "NETTLS_CERT_VERIFICATION_FAILED" ->
             "The certificate could not be verified against the list of \
              trusted authorities"
        | "NETTLS_NAME_VERIFICATION_FAILED" ->
             "The name of the peer does not match the name of the certificate"
        | "NETTLS_USER_VERIFICATION_FAILED" ->
             "The user-supplied verification function did not succeed"
        | "NETTLS_UNEXPECTED_STATE" ->
             "The endpoint is in an unexpected state"
        | _ ->
             G.gnutls_strerror (G.b_error_of_name code)


    let () =
      Netexn.register_printer
        (Exc.TLS_error "")
        (function
          | Exc.TLS_error code ->
               sprintf "Nettls_gnutls.TLS.Error(%s)" code
          | _ ->
               assert false
        )

    let () =
      Netexn.register_printer
        (Exc.TLS_warning "")
        (function
          | Exc.TLS_warning code ->
               sprintf "Nettls_gnutls.TLS.Warning(%s)" code
          | _ ->
               assert false
        )

    let trans_exn f arg =
      try
        f arg
      with
        | G.Error code ->
            raise(Exc.TLS_error (G.gnutls_strerror_name code))


    let parse_pem ?(empty_ok=false) header_tags file f =
      let spec = List.map (fun tag -> (tag, `Base64)) header_tags in
      let blocks =
        Netchannels.with_in_obj_channel
          (new Netchannels.input_channel(open_in file))
          (fun ch -> Netascii_armor.parse spec ch) in
      if not empty_ok && blocks = [] then
        failwith ("Cannot find PEM-encoded objects in file: " ^ file);
      List.map
        (function
          | (tag, `Base64 body) -> f (tag,body#value)
          | _ -> assert false
        )
        blocks

    let create_pem header_tag data =
      let b64 = Netencoding.Base64.encode ~linelength:80 data in
      "-----BEGIN " ^ header_tag ^ "-----\n" ^ 
        b64 ^
      "-----END " ^ header_tag ^ "-----\n"


    let create_config ?(algorithms="NORMAL") ?dh_params ?(verify=fun _ -> true)
                      ?(peer_name_unchecked=false) ~peer_auth 
                      ~credentials () =
      let f() =
        let priority = G.gnutls_priority_init algorithms in
        let dhp_opt =
          match dh_params with
            | None -> None
            | Some(`PKCS3_PEM_file file) ->
                let data =
                  List.hd (parse_pem ["DH PARAMETERS"] file snd) in
                let dhp = G.gnutls_dh_params_init() in
                G.gnutls_dh_params_import_pkcs3 dhp data `Der;
                Some dhp
            | Some(`PKCS3_DER data) ->
                let dhp = G.gnutls_dh_params_init() in
                G.gnutls_dh_params_import_pkcs3 dhp data `Der;
                Some dhp
            | Some(`Generate bits) ->
                let dhp = G.gnutls_dh_params_init() in
                G.gnutls_dh_params_generate2 dhp bits;
                Some dhp in
        { priority;
          dh_params = dhp_opt;
          peer_auth;
          credentials;
          verify;
          peer_name_unchecked
        } in
      trans_exn f ()


    let create_x509_credentials_1 ~system_trust ~trust ~revoke ~keys () =
      let gcred = G.gnutls_certificate_allocate_credentials() in
      if system_trust then (
        match Nettls_gnutls_config.system_trust with
          | `Gnutls ->
               G.gnutls_certificate_set_x509_system_trust gcred
          | `File path ->
               let certs =
                 parse_pem [ "X509 CERTIFICATE"; "CERTIFICATE" ] path snd in
               List.iter
                 (fun data ->
                    G.gnutls_certificate_set_x509_trust_mem gcred data `Der
                 )
                 certs
      );
      List.iter
        (fun crt_spec ->
           let der_crts =
             match crt_spec with
               | `PEM_file file ->
                   parse_pem [ "X509 CERTIFICATE"; "CERTIFICATE" ] file snd
               | `DER l ->
                   l in
           List.iter
             (fun data ->
                G.gnutls_certificate_set_x509_trust_mem gcred data `Der
             )
             der_crts
        )
        trust;
      List.iter
        (fun crl_spec ->
           let der_crls =
             match crl_spec with
               | `PEM_file file ->
                   parse_pem [ "X509 CRL" ] file snd
               | `DER l ->
                   l in
           List.iter
             (fun data ->
                G.gnutls_certificate_set_x509_crl_mem gcred data `Der
             )
             der_crls
        )
        revoke;
      List.iter
        (fun (crts, pkey, pw_opt) ->
           let der_crts =
             match crts with
               | `PEM_file file ->
                   parse_pem [ "X509 CERTIFICATE"; "CERTIFICATE" ] file snd
               | `DER l ->
                   l in
           let gcrts =
             List.map
               (fun data ->
                  let gcrt = G.gnutls_x509_crt_init() in
                  G.gnutls_x509_crt_import gcrt data `Der;
                  gcrt
               )
               der_crts in
           let gpkey = G.gnutls_x509_privkey_init() in
           let pkey1 =
             match pkey with
               | `PEM_file file ->
                   let p =
                     parse_pem
                       [ "RSA PRIVATE KEY";
                         "DSA PRIVATE KEY";
                         "EC PRIVATE KEY";
                         "PRIVATE KEY";
                         "ENCRYPTED PRIVATE KEY"
                       ]
                       file
                       (fun (tag,data) ->
                          match tag with
                            | "RSA PRIVATE KEY" -> `RSA data
                            | "DSA PRIVATE KEY" -> `DSA data
                            | "EC PRIVATE KEY" -> `EC data
                            | "PRIVATE KEY" -> `PKCS8 data
                            | "ENCRYPTED PRIVATE KEY" -> `PKCS8_encrypted data
                            | _ -> assert false
                       ) in
                   (List.hd p :> private_key)
               | other ->
                   other in

           ( match pkey1 with
               | `PEM_file file ->
                   assert false
               | `RSA data ->
                   (* There is no entry point for parsing ONLY this format *)
                   let pem = create_pem "RSA PRIVATE KEY" data in
                   G.gnutls_x509_privkey_import gpkey pem `Pem
               | `DSA data ->
                   (* There is no entry point for parsing ONLY this format *)
                   let pem = create_pem "DSA PRIVATE KEY" data in
                   G.gnutls_x509_privkey_import gpkey pem `Pem
               | `EC data ->
                   (* There is no entry point for parsing ONLY this format *)
                   let pem = create_pem "EC PRIVATE KEY" data in
                   G.gnutls_x509_privkey_import gpkey pem `Pem
               | `PKCS8 data ->
                   G.gnutls_x509_privkey_import_pkcs8 
                     gpkey data `Der "" [`Plain]
               | `PKCS8_encrypted data ->
                   ( match pw_opt with
                       | None ->
                           failwith "No password for encrypted PKCS8 data"
                       | Some pw ->
                           G.gnutls_x509_privkey_import_pkcs8
                             gpkey data `Der pw []
                   )

           );
           G.gnutls_certificate_set_x509_key gcred (Array.of_list gcrts) gpkey
        )
        keys;
      G.gnutls_certificate_set_verify_flags gcred [];
      { gcred = `Certificate gcred }

    let create_x509_credentials ?(system_trust=false) 
                                ?(trust=[]) ?(revoke=[]) ?(keys=[]) () =
      trans_exn
        (create_x509_credentials_1 ~system_trust ~trust ~revoke ~keys)
        ()

    let create_endpoint ~role ~recv ~send ~peer_name config =
      if peer_name=None && 
         role=`Client &&
         not config.peer_name_unchecked &&
         config.peer_auth <> `None
      then
        failwith "TLS configuration error: authentication required, \
                  but no peer_name set";
      let f() =
        let flags = [ (role :> G.gnutls_init_flags_flag) ] in
        let session = G.gnutls_init flags in
        let ep =
          { role;
            recv;
            send;
            config;
            our_cert = None;
            session;
            peer_name;
            state = `Start;
            trans_eof = false;
          } in
        let recv1 mem =
          let n = recv mem in
          if Bigarray.Array1.dim mem > 0 && n=0 then ep.trans_eof <- true;
          n in
        G.b_set_pull_callback session recv1;
        G.b_set_push_callback session send;

        G.gnutls_priority_set session config.priority;
        G.gnutls_credentials_set session config.credentials.gcred;

        if role = `Client then (
          match peer_name with
            | None -> ()
            | Some n -> G.gnutls_server_name_set session `Dns n
        );

        if role = `Server && config.peer_auth <> `None then
          G.gnutls_certificate_server_set_request
            session
            (match config.peer_auth with
               | `Optional -> `Request
               | `Required -> `Require
               | `None -> assert false
            );
        ep
      in
      trans_exn f ()

    exception Stashed of role * config * G.gnutls_session_t * string option *
                           raw_credentials option * state * bool

    let stash_endpoint ep =
      G.b_set_pull_callback ep.session (fun _ -> 0);
      G.b_set_push_callback ep.session (fun _ _ -> 0);
      let exn =
        Stashed(ep.role,
                ep.config,
                ep.session,
                ep.peer_name,
                ep.our_cert,
                ep.state,
                ep.trans_eof) in
      ep.state <- `End;
      exn

    let restore_endpoint ~recv ~send exn =
      match exn with
        | Stashed(role,config,session,peer_name,our_cert,state,trans_eof) ->
             let ep =
               { role; recv; send; config; session; peer_name;
                 our_cert; state; trans_eof
               } in
             let recv1 mem =
               let n = recv mem in
               if Bigarray.Array1.dim mem > 0 && n=0 then ep.trans_eof <- true;
               n in
             G.b_set_pull_callback session recv1;
             G.b_set_push_callback session send;
             ep
        | _ ->
             failwith "Nettls_gnutls.restore_endpoint: bad exception value"

          
    let resume_client ~recv ~send ~peer_name config data =
      let f() =
        let flags = [ `Client ] in
        let session = G.gnutls_init flags in
        G.gnutls_session_set_data session data;
        let ep =
          { role = `Client;
            recv;
            send;
            config;
            our_cert = None;
            session;
            peer_name;
            state = `Start;
            trans_eof = false;
          } in
        let recv1 mem =
          let n = recv mem in
          if Bigarray.Array1.dim mem > 0 && n=0 then ep.trans_eof <- true;
          n in
        G.b_set_pull_callback session recv1;
        G.b_set_push_callback session send;

        G.gnutls_priority_set session config.priority;
        G.gnutls_credentials_set session config.credentials.gcred;
        ep
      in
      trans_exn f ()
          
    let get_state ep = ep.state

    let get_config ep = ep.config

    let at_transport_eof ep = ep.trans_eof

    let endpoint_exn ?(warnings=false) ep f arg =
      try
        f arg
      with
        | G.Error `Again -> 
            if G.gnutls_record_get_direction ep.session then
              raise Exc.EAGAIN_WR
            else
              raise Exc.EAGAIN_RD
        | G.Error `Interrupted ->
            raise (Unix.Unix_error(Unix.EINTR, "Nettls_gnutls", ""))
        | G.Error `Rehandshake ->
            if ep.state = `Switching then
              raise (Exc.TLS_switch_response true)
            else
              raise Exc.TLS_switch_request
        | G.Error (`Warning_alert_received as code) ->
            if G.gnutls_alert_get ep.session = `No_renegotiation then
              raise (Exc.TLS_switch_response false)
            else
              let code' = G.gnutls_strerror_name code in
              if warnings then
                raise(Exc.TLS_warning code')
              else
                raise(Exc.TLS_error code')
        | G.Error code ->
              let code' = G.gnutls_strerror_name code in
            if warnings && not(G.gnutls_error_is_fatal code) then
              raise(Exc.TLS_warning code')
            else
              raise(Exc.TLS_error code')

    let unexpected_state() =
      raise(Exc.TLS_error "NETTLS_UNEXPECTED_STATE")

    let update_our_cert ep =
      (* our_cert: if the session is resumed, our_cert should already be
         filled in by the [retrieve] callback (because GnuTLS omit this
         certificate in its own serialization format)
       *)
      if ep.our_cert = None then
        (* So far only X509... *)
        trans_exn
          (fun () ->
             ep.our_cert <- 
               Some (try
                        `X509 (G.gnutls_certificate_get_ours ep.session)
                      with
                        | G.Null_pointer -> `Anonymous
                    )
          )
          ()


    let hello ep =
      if ep.state <> `Start && ep.state <> `Handshake && 
           ep.state <> `Switching then
        unexpected_state();
      ep.state <- `Handshake;
      endpoint_exn
        ~warnings:true
        ep
        G.gnutls_handshake
        ep.session;
      update_our_cert ep;
      ep.state <- `Data_rw

    let bye ep how =
      if ep.state <> `End then (
        if ep.state <> `Data_rw && ep.state <> `Data_r && ep.state <> `Data_w
        then 
          unexpected_state();
        if how <> Unix.SHUTDOWN_RECEIVE then (
          let ghow, new_state =
            match how with
              | Unix.SHUTDOWN_SEND ->
                   `Wr, (if ep.state = `Data_w then `End else `Data_r)
              | Unix.SHUTDOWN_ALL ->
                   `Rdwr, `End
              | Unix.SHUTDOWN_RECEIVE ->
                   assert false in
          endpoint_exn
            ~warnings:true
            ep
            (G.gnutls_bye ep.session)
            ghow;
          ep.state <- new_state
        )
      )

    let verify ep =
      let f() =
        if G.gnutls_certificate_get_peers ep.session = [| |] then (
          if ep.config.peer_auth <> `Required then
            raise(Exc.TLS_error (G.gnutls_strerror_name `No_certificate_found))
        )
        else (
          if ep.config.peer_auth <> `None then (
            let status_l = G.gnutls_certificate_verify_peers2 ep.session in
            if status_l <> [] then
              raise(Exc.TLS_error "NETTLS_CERT_VERIFICATION_FAILED");
(*
              failwith(sprintf "Certificate verification failed with codes: " ^ 
                         (String.concat ", " 
                            (List.map 
                               G.string_of_verification_status_flag
                               status_l)));
 *)
            if not ep.config.peer_name_unchecked then ( 
              match ep.peer_name with
                | None -> ()
                | Some pn ->
                     let der_peer_certs = 
                       G.gnutls_certificate_get_peers ep.session in
                     assert(der_peer_certs <> [| |]);
                     let peer_cert = G.gnutls_x509_crt_init() in
                     G.gnutls_x509_crt_import peer_cert der_peer_certs.(0) `Der;
                     let ok = G.gnutls_x509_crt_check_hostname peer_cert pn in
                     if not ok then
                       raise(Exc.TLS_error "NETTLS_NAME_VERIFICATION_FAILED");
            );
            if not (ep.config.verify ep) then
              raise(Exc.TLS_error "NETTLS_USER_VERIFICATION_FAILED");
          )
        ) in
      trans_exn f ()

    let get_endpoint_creds ep =
      match ep.our_cert with
        | Some c -> c
        | None -> failwith "get_endpoint_creds: unavailable"

    let get_peer_creds ep =
      (* So far only X509... *)
      trans_exn
        (fun () ->
           try
             let certs = G.gnutls_certificate_get_peers ep.session in
             if certs = [| |] then
               `Anonymous
             else
               `X509 certs.(0)
           with
             | G.Null_pointer -> `Anonymous
        )
        ()

    let get_peer_creds_list ep =
      (* So far only X509... *)
      trans_exn
        (fun () ->
           try
             let certs = G.gnutls_certificate_get_peers ep.session in
             if certs = [| |] then
               [ `Anonymous ]
             else
               List.map (fun c -> `X509 c) (Array.to_list certs)
           with
             | G.Null_pointer -> [ `Anonymous ]
        )
        ()

    let switch ep conf =
      if ep.state <> `Data_rw && ep.state <> `Data_w && ep.state <> `Switching
      then
        unexpected_state();
      ep.state <- `Switching;
      ep.config <- conf;
      endpoint_exn
        ~warnings:true
        ep
        G.gnutls_rehandshake
        ep.session;
      ep.state <- `Data_rs


    let accept_switch ep conf =
      if ep.state <> `Data_rw && ep.state <> `Data_w && ep.state <> `Accepting 
      then
        unexpected_state();
      ep.state <- `Accepting;
      ep.config <- conf;
      endpoint_exn
        ~warnings:true
        ep
        G.gnutls_handshake
        ep.session;
      update_our_cert ep;
      ep.state <- `Data_rw


    let refuse_switch ep =
      if ep.state <> `Data_rw && ep.state <> `Data_w && ep.state <> `Refusing 
      then
        unexpected_state();
      ep.state <- `Refusing;
      endpoint_exn
        ~warnings:true
        ep
        (G.gnutls_alert_send ep.session `Warning)
        `No_renegotiation;
      ep.state <- `Data_rw


    let send ep buf n =
      if ep.state <> `Data_rw && ep.state <> `Data_w then
        unexpected_state();
      endpoint_exn
        ~warnings:true
        ep
        (G.gnutls_record_send ep.session buf)
        n

    let recv ep buf =
      if ep.state <> `Data_rw && ep.state <> `Data_r && ep.state <> `Data_rs 
      then
        unexpected_state();
      let n =
        endpoint_exn
          ~warnings:true
          ep
          (G.gnutls_record_recv ep.session)
          buf in
      if Bigarray.Array1.dim buf > 0 && n=0 then
        ep.state <- (if ep.state = `Data_rw then `Data_w else `End);
      n

    let recv_will_not_block ep =
      let f() =
        G.gnutls_record_check_pending ep.session > 0 in
      trans_exn f ()

    let get_session_id ep =
      trans_exn
        (fun () ->
           G.gnutls_session_get_id ep.session
        )
        ()

    let get_session_data ep =
      trans_exn
        (fun () ->
           G.gnutls_session_get_data ep.session
        )
        ()

    let get_cipher_suite_type ep =
      "X509"  (* so far only this is supported *)

    let get_cipher_algo ep =
      let f() =
        G.gnutls_cipher_get_name (G.gnutls_cipher_get ep.session) in
      trans_exn f ()

    let get_kx_algo ep =
      let f() =
        G.gnutls_kx_get_name (G.gnutls_kx_get ep.session) in
      trans_exn f ()

    let get_mac_algo ep =
      let f() =
        G.gnutls_mac_get_name (G.gnutls_mac_get ep.session) in
      trans_exn f ()

    let get_compression_algo ep =
      let f() =
        G.gnutls_compression_get_name (G.gnutls_compression_get ep.session) in
      trans_exn f ()

    let get_cert_type ep =
      let f() =
        G.gnutls_certificate_type_get_name
          (G.gnutls_certificate_type_get ep.session) in
      trans_exn f ()
      
    let get_protocol ep =
      let f() =
        G.gnutls_protocol_get_name (G.gnutls_protocol_get_version ep.session) in
      trans_exn f ()

    let get_addressed_servers ep =
      let rec get k =
        try
          let n1, t = G.gnutls_server_name_get ep.session k in
          let n2 =
            match t with
              | `Dns -> `Domain n1 in
          n2 :: get(k+1)
        with
          | G.Error `Requested_data_not_available ->
              [] in
      trans_exn get 0

    let set_session_cache ~store ~remove ~retrieve ep =
      let g_store key data =
        update_our_cert ep;
        let r =
          { ser_data = data;
            ser_our_cert = ep.our_cert
          } in
        store key (Marshal.to_string r []) in
      let g_retrieve key =
        let s = retrieve key in
        let r = (Marshal.from_string s 0 : serialized_session) in
        (* HACK: *)
        ep.our_cert <- r.ser_our_cert;
        r.ser_data in
      G.b_set_db_callbacks ep.session g_store remove g_retrieve

    let gnutls_credentials c = c.gcred
    let gnutls_session ep = ep.session
  end


let make_tls (exc : (module Netsys_crypto_types.TLS_EXCEPTIONS)) =
  let module Self =
    struct
      let self = ref Not_found
    end in
  let module Exc =
    (val exc : Netsys_crypto_types.TLS_EXCEPTIONS) in
  let module Impl =
    Make_TLS_1(Self)(Exc) in
  let () =
    Self.self := I (module Impl) in
  (module Impl : GNUTLS_PROVIDER)


(*
module Make_TLS (Exc:Netsys_crypto_types.TLS_EXCEPTIONS) : GNUTLS_PROVIDER =
  (val make_tls (module Exc) : GNUTLS_PROVIDER)
 *)

module GNUTLS = (val make_tls (module Netsys_types))
module TLS = (GNUTLS : Netsys_crypto_types.TLS_PROVIDER)

let gnutls = (module GNUTLS : GNUTLS_PROVIDER)
let tls = (module TLS : Netsys_crypto_types.TLS_PROVIDER)


let endpoint ep =
  let module EP =
    struct
      module TLS = GNUTLS
      let endpoint = ep
    end in
  (module EP : GNUTLS_ENDPOINT)

let downcast p =
  let module P = (val p : Netsys_crypto_types.TLS_PROVIDER) in
  match P.implementation() with
    | I tls -> tls
    | _ -> raise Not_found

let downcast_endpoint ep_mod =
  let module EP = (val ep_mod : Netsys_crypto_types.TLS_ENDPOINT) in
  let module T = (val downcast (module EP.TLS)) in
  let module EP1 =
    struct
      module TLS = T
      let endpoint = (Obj.magic EP.endpoint)
    end in
  (module EP1 : GNUTLS_ENDPOINT)


let init() =
  Nettls_gnutls_bindings.gnutls_global_init();
  Netsys_crypto.set_current_tls
    (module TLS : Netsys_crypto_types.TLS_PROVIDER)


let () =
  init()
