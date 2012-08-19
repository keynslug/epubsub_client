%
% EPubSub client application entry.
%

-module(epubsub_client_sup).
-behaviour(supervisor).

%%

-export([start_link/0, init/1]).

%%

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%%

init([]) ->
    {ok, {
        {one_for_one, 5, 10}, [
            supstance:supervisor(epubsub_client_ws_sup, local, global),
            supstance:transient(epubsub_client_stress_driver, local, global)
        ]}
    }.
