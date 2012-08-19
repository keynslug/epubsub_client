%
% EPubSub websocket clients supervisor.
%

-module(epubsub_client_ws_sup).
-behaviour(supervisor).

-include("epubsub_client_logger.hrl").

%%

-export([
    start_link/2,
    start_client/2
]).

-export([init/1]).

%%

start_link(Name, Options) ->
    supervisor:start_link(Name, ?MODULE, Options).

start_client(SupRef, ID) ->
    supervisor:start_child(SupRef, [ID]).

%%

init(Options) ->
    ?LOG_INFO("Starting..."),
    Module = epubsub_client_ws,
    [Host, Port, Path] = deepprops:values([{host, "127.0.0.1"}, {port, 80}, {path, "/"}], Options),
    WsOptions = {Host, Port, Path},
    {ok, {
        {simple_one_for_one, 1, 1}, [
            {Module, {Module, start_link, [WsOptions]}, temporary, 1000, worker, [Module]}
        ]
    }}.
