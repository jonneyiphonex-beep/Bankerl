-module(bankerl_app).
-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    Port = application:get_env(bankerl, port, 7474),
    BindIp = application:get_env(bankerl, bind_ip, {127, 0, 0, 1}),
    DataFile = application:get_env(bankerl, data_file, "data/bankerl.db"),
    bankerl_sup:start_link(Port, DataFile, BindIp).

stop(_State) ->
    ok.