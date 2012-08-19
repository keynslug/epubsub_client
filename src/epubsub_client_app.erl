%
% EPubSub client application behaviour.
%

-module(epubsub_client_app).
-behaviour(application).

%%

-export([start/2, stop/1]).

%%

start(_StartType, _StartArgs) ->
    epubsub_client_sup:start_link().

stop(_State) ->
    ok.
