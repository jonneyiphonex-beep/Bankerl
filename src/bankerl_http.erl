-module(bankerl_http).
-behaviour(gen_server).

-export([start_link/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(MAX_HEADERS, 16384).
-define(MAX_BODY, 65536).

start_link(Port, BindIp) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, {Port, BindIp}, []).

init({Port, BindIp}) ->
    {ok, Socket} = gen_tcp:listen(Port,
      [binary, {packet, raw}, {active, false}, {reuseaddr, true},
    {ip, BindIp}, {backlog, 128}]),
    StaticDir = filename:join(code:priv_dir(bankerl), "www"),
    Acceptor = spawn_link(fun() -> accept_loop(Socket, StaticDir) end),
    {ok, #{socket => Socket, acceptor => Acceptor}}.

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(_Message, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, State) ->
    gen_tcp:close(maps:get(socket, State)),
    ok.

code_change(_OldVersion, State, _Extra) ->
    {ok, State}.

accept_loop(Socket, StaticDir) ->
    case gen_tcp:accept(Socket) of
        {ok, Client} ->
            spawn(fun() -> handle_client(Client, StaticDir) end),
            accept_loop(Socket, StaticDir);
        {error, closed} -> ok;
        {error, _Reason} -> accept_loop(Socket, StaticDir)
    end.

handle_client(Client, StaticDir) ->
    try read_request(Client) of
        {ok, Request} -> route(Client, Request, StaticDir);
        {error, _Reason} -> respond_json(Client, 400, #{error => bad_request}, [])
    catch
        _:_ -> respond_json(Client, 500, #{error => internal_error}, [])
    after
        gen_tcp:close(Client)
    end.

read_request(Socket) ->
    case read_headers(Socket, <<>>) of
        {ok, HeaderBlock, Remainder} ->
            parse_request(Socket, HeaderBlock, Remainder);
        Error -> Error
    end.

read_headers(_Socket, Buffer) when byte_size(Buffer) > ?MAX_HEADERS ->
    {error, headers_too_large};
read_headers(Socket, Buffer) ->
    case binary:match(Buffer, <<"\r\n\r\n">>) of
        {Offset, 4} ->
            HeaderBlock = binary:part(Buffer, 0, Offset),
            Remainder = binary:part(Buffer, Offset + 4,
                                     byte_size(Buffer) - Offset - 4),
            {ok, HeaderBlock, Remainder};
        nomatch ->
            case gen_tcp:recv(Socket, 0, 5000) of
                {ok, More} -> read_headers(Socket, <<Buffer/binary, More/binary>>);
                Error -> Error
            end
    end.

parse_request(Socket, HeaderBlock, Remainder) ->
    case binary:split(HeaderBlock, <<"\r\n">>, [global]) of
        [RequestLine | HeaderLines] ->
            case binary:split(RequestLine, <<" ">>, [global]) of
                [Method, Target, _Version] ->
                    Headers = parse_headers(HeaderLines, #{}),
                    case content_length(Headers) of
                        {ok, Length} when Length =< ?MAX_BODY ->
                            case read_body(Socket, Remainder, Length) of
                                {ok, Body} ->
                                    [Path | _] = binary:split(Target, <<"?">>),
                                    {ok, #{method => Method, path => Path,
                                           headers => Headers, body => Body}};
                                Error -> Error
                            end;
                        _ -> {error, invalid_content_length}
                    end;
                _ -> {error, invalid_request_line}
            end;
        _ -> {error, empty_request}
    end.

parse_headers([], Headers) -> Headers;
parse_headers([Line | Rest], Headers) ->
    case binary:match(Line, <<":">>) of
        {Offset, 1} ->
            Name = binary:part(Line, 0, Offset),
            Value = binary:part(Line, Offset + 1, byte_size(Line) - Offset - 1),
            Key = list_to_binary(string:lowercase(string:trim(binary_to_list(Name)))),
            CleanValue = list_to_binary(string:trim(binary_to_list(Value))),
            parse_headers(Rest, Headers#{Key => CleanValue});
        nomatch -> parse_headers(Rest, Headers)
    end.

content_length(Headers) ->
    try binary_to_integer(maps:get(<<"content-length">>, Headers, <<"0">>)) of
        Length when Length >= 0 -> {ok, Length};
        _ -> error
    catch
        _:_ -> error
    end.

read_body(_Socket, Buffer, Length) when byte_size(Buffer) >= Length ->
    {ok, binary:part(Buffer, 0, Length)};
read_body(Socket, Buffer, Length) ->
    Missing = Length - byte_size(Buffer),
    case gen_tcp:recv(Socket, Missing, 5000) of
        {ok, More} -> read_body(Socket, <<Buffer/binary, More/binary>>, Length);
        Error -> Error
    end.

route(Client, #{method := <<"GET">>, path := <<"/">>}, StaticDir) ->
    serve_static(Client, filename:join(StaticDir, "index.html"), "text/html; charset=utf-8");
route(Client, #{method := <<"GET">>, path := <<"/app.css">>}, StaticDir) ->
    serve_static(Client, filename:join(StaticDir, "app.css"), "text/css; charset=utf-8");
route(Client, #{method := <<"GET">>, path := <<"/app.js">>}, StaticDir) ->
    serve_static(Client, filename:join(StaticDir, "app.js"),
                 "text/javascript; charset=utf-8");
route(Client, #{method := <<"GET">>, path := <<"/openapi.yaml">>}, StaticDir) ->
    SpecDir = filename:dirname(StaticDir),
    serve_static(Client, filename:join(SpecDir, "openapi.yaml"),
                 "application/yaml; charset=utf-8");
route(Client, #{method := <<"GET">>, path := <<"/api/me">>, headers := Headers}, _StaticDir) ->
    store_result(Client, bankerl_store:dashboard(session_token(Headers)));
route(Client, #{method := <<"POST">>, path := <<"/api/register">>, body := Body}, _StaticDir) ->
    Values = form_values(Body),
    case bankerl_store:register(value(Values, "name"), value(Values, "email"),
                                value(Values, "password")) of
        {ok, Token, Dashboard} ->
            respond_json(Client, 201, Dashboard, [session_cookie(Token)]);
        Error -> store_result(Client, Error)
    end;
route(Client, #{method := <<"POST">>, path := <<"/api/login">>, body := Body}, _StaticDir) ->
    Values = form_values(Body),
    case bankerl_store:login(value(Values, "customer_number"),
                             value(Values, "password")) of
        {ok, Token, Dashboard} ->
            respond_json(Client, 200, Dashboard, [session_cookie(Token)]);
        Error -> store_result(Client, Error)
    end;
route(Client, #{method := <<"POST">>, path := <<"/api/logout">>, headers := Headers}, _StaticDir) ->
    ok = bankerl_store:logout(session_token(Headers)),
    respond_json(Client, 200, #{ok => true}, [clear_session_cookie()]);
route(Client, #{method := <<"POST">>, path := <<"/api/deposit">>,
                headers := Headers, body := Body}, _StaticDir) ->
    amount_action(Client, Headers, Body, fun bankerl_store:deposit/2);
route(Client, #{method := <<"POST">>, path := <<"/api/withdraw">>,
                headers := Headers, body := Body}, _StaticDir) ->
    amount_action(Client, Headers, Body, fun bankerl_store:withdraw/2);
route(Client, #{method := <<"POST">>, path := <<"/api/transfer">>,
                headers := Headers, body := Body}, _StaticDir) ->
    Values = form_values(Body),
    case parse_money(value(Values, "amount")) of
        {ok, Amount} ->
            store_result(Client, bankerl_store:transfer(session_token(Headers),
              value(Values, "email"), Amount, value(Values, "note")));
        error -> respond_json(Client, 400, #{error => invalid_amount}, [])
    end;
route(Client, #{method := <<"POST">>, path := <<"/api/accounts/savings">>,
                headers := Headers}, _StaticDir) ->
    store_result(Client, bankerl_store:open_savings(session_token(Headers)));
route(Client, #{method := <<"POST">>, path := <<"/api/accounts/move">>,
                headers := Headers, body := Body}, _StaticDir) ->
    Values = form_values(Body),
    case parse_money(value(Values, "amount")) of
        {ok, Amount} ->
            store_result(Client, bankerl_store:move_funds(session_token(Headers),
              value(Values, "from"), value(Values, "to"), Amount));
        error -> respond_json(Client, 400, #{error => invalid_amount}, [])
    end;
route(Client, #{method := <<"POST">>, path := <<"/api/zakat">>,
                headers := Headers, body := Body}, _StaticDir) ->
    Values = form_values(Body),
    case parse_money(value(Values, "nisab")) of
        {ok, Nisab} ->
            store_result(Client, bankerl_store:calculate_zakat(session_token(Headers), Nisab));
        error -> respond_json(Client, 400, #{error => invalid_nisab}, [])
    end;
route(Client, _Request, _StaticDir) ->
    respond_json(Client, 404, #{error => not_found}, []).

amount_action(Client, Headers, Body, Action) ->
    Values = form_values(Body),
    case parse_money(value(Values, "amount")) of
        {ok, Amount} -> store_result(Client, Action(session_token(Headers), Amount));
        error -> respond_json(Client, 400, #{error => invalid_amount}, [])
    end.

store_result(Client, {ok, Result}) ->
    respond_json(Client, 200, Result, []);
store_result(Client, {error, Reason}) ->
    Status = case Reason of
                 unauthorized -> 401;
                 recipient_not_found -> 404;
                 _ -> 400
             end,
    respond_json(Client, Status, #{error => Reason}, []).

form_values(Body) ->
    try maps:from_list(uri_string:dissect_query(binary_to_list(Body)))
    catch _:_ -> #{} end.

value(Values, Key) ->
    maps:get(Key, Values, "").

parse_money(Value) when is_list(Value), length(Value) =< 12 ->
    case string:split(Value, ".", all) of
        [Dollars] -> cents(Dollars, "00");
        [Dollars, Cents] when length(Cents) =:= 1 -> cents(Dollars, Cents ++ "0");
        [Dollars, Cents] when length(Cents) =:= 2 -> cents(Dollars, Cents);
        _ -> error
    end;
parse_money(_Value) ->
    error.

cents(Dollars, Cents) ->
    case {digits(Dollars), digits(Cents)} of
        {true, true} ->
            Amount = list_to_integer(Dollars) * 100 + list_to_integer(Cents),
            case Amount > 0 of true -> {ok, Amount}; false -> error end;
        _ -> error
    end.

digits([]) -> false;
digits(Value) -> lists:all(fun(Character) -> Character >= $0 andalso Character =< $9 end,
                           Value).

session_token(Headers) ->
    Cookie = maps:get(<<"cookie">>, Headers, <<>>),
    Pairs = [string:trim(binary_to_list(Pair)) || Pair <-
               binary:split(Cookie, <<";">>, [global])],
    case [Value || Pair <- Pairs,
                   ["bankerl_session", Value] <- [string:split(Pair, "=", all)]] of
        [Token | _] -> Token;
        [] -> ""
    end.

session_cookie(Token) ->
    {"Set-Cookie", "bankerl_session=" ++ Token ++
     "; Path=/; HttpOnly; SameSite=Strict; Max-Age=86400"}.

clear_session_cookie() ->
    {"Set-Cookie", "bankerl_session=; Path=/; HttpOnly; SameSite=Strict; Max-Age=0"}.

serve_static(Client, File, ContentType) ->
    case file:read_file(File) of
        {ok, Body} -> respond(Client, 200, ContentType, Body, []);
        _ -> respond_json(Client, 404, #{error => not_found}, [])
    end.

respond_json(Client, Status, Value, ExtraHeaders) ->
    respond(Client, Status, "application/json; charset=utf-8",
            iolist_to_binary(encode_json(Value)), ExtraHeaders).

respond(Client, Status, ContentType, Body, ExtraHeaders) ->
    Headers = [{"Content-Type", ContentType},
      {"Content-Length", integer_to_list(byte_size(Body))},
      {"Connection", "close"},
      {"Cache-Control", "no-store"},
      {"X-Content-Type-Options", "nosniff"},
      {"Referrer-Policy", "no-referrer"},
      {"Content-Security-Policy", "default-src 'self'; script-src 'self'; "
       "style-src 'self'; img-src 'self' data:; connect-src 'self'; "
       "base-uri 'none'; frame-ancestors 'none'; form-action 'self'"}] ++ ExtraHeaders,
    HeaderData = [[Name, ": ", Value, "\r\n"] || {Name, Value} <- Headers],
    StatusLine = ["HTTP/1.1 ", integer_to_list(Status), " ", reason_phrase(Status),
                  "\r\n"],
    gen_tcp:send(Client, [StatusLine, HeaderData, "\r\n", Body]).

reason_phrase(200) -> "OK";
reason_phrase(201) -> "Created";
reason_phrase(400) -> "Bad Request";
reason_phrase(401) -> "Unauthorized";
reason_phrase(404) -> "Not Found";
reason_phrase(500) -> "Internal Server Error";
reason_phrase(_) -> "OK".

encode_json(Value) when is_map(Value) ->
    Pairs = maps:to_list(Value),
    Encoded = [[encode_json(key_binary(Key)), $:, encode_json(Entry)] ||
                 {Key, Entry} <- Pairs],
    [$\{, lists:join($,, Encoded), $\}];
encode_json(Value) when is_list(Value) ->
    [$[, lists:join($,, [encode_json(Entry) || Entry <- Value]), $]];
encode_json(Value) when is_binary(Value) ->
    [$", escape_json(Value), $"];
encode_json(Value) when is_integer(Value) ->
    integer_to_list(Value);
encode_json(true) -> "true";
encode_json(false) -> "false";
encode_json(null) -> "null";
encode_json(Value) when is_atom(Value) ->
    encode_json(atom_to_binary(Value, utf8));
encode_json(_Value) -> "null".

key_binary(Key) when is_atom(Key) -> atom_to_binary(Key, utf8);
key_binary(Key) when is_binary(Key) -> Key.

escape_json(Value) ->
    [case Byte of
         $" -> "\\\"";
         $\\ -> "\\\\";
         $\b -> "\\b";
         $\f -> "\\f";
         $\n -> "\\n";
         $\r -> "\\r";
         $\t -> "\\t";
         _ when Byte < 32 -> io_lib:format("\\u~4.16.0B", [Byte]);
         _ -> <<Byte>>
     end || <<Byte>> <= Value].