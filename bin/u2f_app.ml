open Lwt.Infix

let users = Hashtbl.create 7

let challenges = Hashtbl.create 7

let retrieve_form request =
  Dream.body request >|= fun body ->
  let form = Dream__pure.Formats.from_form_urlencoded body in
  List.stable_sort (fun (key, _) (key', _) -> String.compare key key') form

let to_string err = Format.asprintf "%a" U2f.pp_error err

let add_routes t =
  let main _req =
    Dream.html (Template.overview users challenges)
  in

  let register _req =
    let random_user = Base64.(encode_string ~pad:false ~alphabet:uri_safe_alphabet (Cstruct.to_string (Mirage_crypto_rng.generate 10))) in
    let challenge, rr = U2f.register_request t in
    Hashtbl.replace challenges random_user challenge;
    Dream.html (Template.register_view rr random_user)
  in

  let register_finish req =
    retrieve_form req >>= fun data ->
    let token = List.assoc "token" data in
    let user = List.assoc "username" data in
    let challenge = Hashtbl.find challenges user in
    match U2f.register_response t challenge token with
    | Ok (key, kh, cert) ->
      Logs.app (fun m -> m "registered %s" user);
      Hashtbl.replace users user (key, kh, cert);
      Hashtbl.remove challenges user;
      Dream.html
        (Template.overview_note "Successfully registered"
           ~user users challenges)
    | Error e ->
      Logs.warn (fun m -> m "error %a" U2f.pp_error e);
      let err = to_string e in
      Dream.html
        (Template.overview_note ("Registration failed " ^ err)
           ~user users challenges)
  in

  let authenticate req =
    let user = Dream.param "user" req in
    let (_, kh, _) = Hashtbl.find users user in
    let challenge, ar = U2f.authentication_request t kh in
    Hashtbl.replace challenges user challenge;
    Dream.html (Template.authenticate_view ar user)
  in

  let authenticate_finish req =
    retrieve_form req >>= fun data ->
    let user = List.assoc "username" data in
    let challenge = Hashtbl.find challenges user in
    Hashtbl.remove challenges user;
    let key, kh, _ = Hashtbl.find users user in
    let token = List.assoc "token" data in
    match U2f.authentication_response t key kh challenge token with
    | Ok (_user_present, _counter) ->
      Hashtbl.remove challenges user;
      Dream.html (Template.overview_note "Successfully authenticated"
                    ~user users challenges)
    | Error e ->
      Logs.warn (fun m -> m "error %a" U2f.pp_error e);
      let err = to_string e in
      Dream.html
        (Template.overview_note ("Authentication failure: " ^ err)
           ~user users challenges)
  in

  let u2f_api _req =
    Dream.respond ~headers:[("Content-type", "application/javascript")]
      [%blob "u2f-api-1.1.js"]
  in

  Dream.router [
    Dream.get "/" main;
    Dream.get "/register" register;
    Dream.post "/register_finish" register_finish;
    Dream.get "/authenticate/:user" authenticate;
    Dream.post "/authenticate_finish" authenticate_finish;
    Dream.get "/static/u2f-api-1.1.js" u2f_api;
  ]


let setup_app level port host https =
  let u2f = U2f.create "https://u2f-demo.robur.coop" in
  let level = match level with None -> None | Some Logs.Debug -> Some `Debug | Some Info -> Some `Info | Some Warning -> Some `Warning | Some Error -> Some `Error | Some App -> None in
  Dream.initialize_log ?level ();
  Dream.run ~port ~interface:host ~https
  @@ Dream.logger
  @@ add_routes u2f
  @@ Dream.not_found

open Cmdliner

let port =
  let doc = "port" in
  Arg.(value & opt int 4000 & info [ "p"; "port" ] ~doc)

let host =
  let doc = "host" in
  Arg.(value & opt string "0.0.0.0" & info [ "h"; "host" ] ~doc)

let tls =
  let doc = "tls" in
  Arg.(value & flag & info [ "tls" ] ~doc)

let () =
  let term = Term.(pure setup_app $ Logs_cli.level () $ port $ host $ tls) in
  let info = Term.info "U2f app" ~doc:"U2f app" ~man:[] in
  match Term.eval (term, info) with
  | `Ok () -> exit 0
  | `Error _ -> exit 1
  | _ -> exit 0
