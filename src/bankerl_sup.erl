-module(bankerl_sup).
-behaviour(supervisor).

-export([start_link/3, init/1]).

start_link(Port, DataFile, BindIp) ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, {Port, DataFile, BindIp}).

init({Port, DataFile, BindIp}) ->
    Store = #{id => bankerl_store,
              start => {bankerl_store, start_link, [DataFile]},
              restart => permanent,
              shutdown => 5000,
              type => worker,
              modules => [bankerl_store]},
    Http = #{id => bankerl_http,
             start => {bankerl_http, start_link, [Port, BindIp]},
             restart => permanent,
             shutdown => 5000,
             type => worker,
             modules => [bankerl_http]},
    {ok, {{one_for_one, 5, 10}, [Store, Http]}}.