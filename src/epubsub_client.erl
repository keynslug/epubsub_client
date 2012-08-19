%
% EPubSub client application entry.
%

-module(epubsub_client).

-export([start/0, stop/0]).

%

start() ->
    start(?MODULE).

start(App) ->
    do_start(App, application:start(App, permanent)).

stop() ->
    application:stop(?MODULE).

%

do_start(_, ok) ->
    ok;

do_start(_, {error, {already_started, _App}}) ->
    ok;

do_start(App, {error, {not_started, Dep}}) when App =/= Dep ->
    ok = start(Dep),
    start(App);

do_start(App, {error, Reason}) ->
    erlang:error({app_start_failed, App, Reason}).
