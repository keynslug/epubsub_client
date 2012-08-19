%
% EPubSub client service that drives stress loads with websocket clients.
%

-module(epubsub_client_stress_driver).
-behaviour(gen_server).

-include("epubsub_client_logger.hrl").

%% API
-export([
    start_link/1,
    start_link/2,
    stop/1
]).

%% Callbacks
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-record(state, {
    weight = 1,
    agenda :: proplists:proplist(),
    workers :: dict()
}).

%

start_link(Name, Options) ->
    gen_server:start_link(Name, ?MODULE, Options, []).

start_link(Options) ->
    gen_server:start_link(?MODULE, Options, []).

stop(Name) ->
    gen_server:call(Name, stop).

%

init(Options) ->
    ?LOG_INFO("Starting stress driver..."),
    process_flag(trap_exit, true),
    [Num, StartInterval, Lifetime, SendInterval, Weight] = deepprops:values([
        {worker_num, 100},
        {start_interval, 1000},
        {worker_lifetime, 60000},
        {send_interval, 10000},
        {payload_weight, 60}
    ], Options),
    Agenda = agenda(Num, StartInterval, Lifetime, SendInterval),
    State = #state{weight = Weight, agenda = Agenda, workers = dict:new()},
    {ok, State, 1}.

handle_call(stop, _From, State) ->
    {stop, shutdown, ok, State};

handle_call(Unexpected, _From, State) ->
    ?LOG_WARN("Unexpected call received: ~p", [Unexpected]),
    {noreply, State}.

handle_cast(Unexpected, State) ->
    ?LOG_WARN("Unexpected cast received: ~p", [Unexpected]),
    {noreply, State}.

handle_info({'EXIT', Pid, Reason}, State = #state{workers = Workers}) ->
    ?LOG_DEBUG("Process ~p died with reason ~p and sent exit signal", [Pid, Reason]),
    FinalWorkers = dict:filter(fun (_, Value) -> Value =/= Pid end, Workers),
    FinalState = State#state{workers = FinalWorkers},
    case dict:size(FinalWorkers) of
        0 ->
            ?LOG_INFO("Workers done"),
            {stop, shutdown, FinalState};
        _ ->
            {noreply, FinalState}
    end;

handle_info(timeout, State = #state{agenda = [], workers = Workers}) ->
    case dict:size(Workers) of
        0 ->
            ?LOG_INFO("Done"),
            {stop, shutdown, State};
        N ->
            ?LOG_WARN("Done, but ~p workers are still active", [N]),
            {noreply, State}
    end;

handle_info(timeout, State = #state{agenda = [TimedAction | Rest]}) ->
    ?LOG_DEBUG("Performing action ~p", [TimedAction]),
    Action = get_action(TimedAction),    
    FinalState = take_action(Action, State),
    Interval = get_interval(TimedAction, Rest),
    erlang:send_after(Interval, self(), timeout),
    {noreply, FinalState#state{agenda = Rest}};

handle_info(Unexpected, State) ->
    ?LOG_WARN("Unexpected message received: ~p", [Unexpected]),
    {noreply, State}.

terminate(Reason, _) ->
    ?LOG_INFO("Terminated with reason: ~p", [Reason]),
    ok.

code_change(_, State, _) ->
    {ok, State}.

%

take_action({start, N}, State = #state{workers = Workers}) ->
    case dict:is_key(N, Workers) of
        true ->
            ?LOG_WARN("Worker ~p is already started", [N]),
            State;
        _ ->
            Result = epubsub_client_ws_sup:start_client(epubsub_client_ws_sup, N),
            case Result of
                {ok, Pid} ->
                    ?LOG_INFO("Worker ~p started with pid ~p", [N, Pid]),
                    true = link(Pid),
                    State#state{workers = dict:store(N, Pid, Workers)};
                Error ->
                    ?LOG_ERROR("Worker ~p failed to start: ~p", [N, Error]),
                    State
            end
    end;

take_action({stop, N}, State = #state{workers = Workers}) ->
    case dict:find(N, Workers) of
        {ok, Pid} ->
            ?LOG_INFO("Worker ~p requested to stop", [N]),
            epubsub_client_ws:stop(Pid);
        _ ->
            ?LOG_WARN("Worker ~p is not registered", [N])
    end,
    State;

take_action({action, N}, State = #state{workers = Workers, weight = Weight}) ->
    case dict:find(N, Workers) of
        {ok, Pid} ->
            ?LOG_INFO("Worker ~p requested to send message", [N]),
            epubsub_client_ws:send(Pid, random_payload(Weight));
        _ ->
            ?LOG_WARN("Worker ~p is not registered", [N])
    end,
    State;

take_action(_, State) ->
    State.

%

agenda(Num, StartInterval, Lifetime, SendInterval) ->
    List = fill(Num, StartInterval, Lifetime, SendInterval, []),
    lists:sort(List).

fill(0, _Interval, _Time, _ActionInterval, Acc) ->
    Acc;

fill(N, Interval, Time, ActionInterval, Acc) ->
    Ts = Interval * (N - 1),
    fill(
        N - 1, Interval, Time, ActionInterval,
        fill_actions(
            N, ActionInterval, Ts + ActionInterval, Ts + Time, 
            [make_action(Ts, {start, N}), make_action(Ts + Time, {stop, N}) | Acc]
        )
    ).

fill_actions(_N, _Interval, Ts, Limit, Acc) when Limit < Ts ->
    Acc;

fill_actions(N, Interval, Ts, Limit, Acc) ->
    fill_actions(N, Interval, Ts + Interval, Limit, [make_action(Ts, {action, N}) | Acc]).

%

make_action(Ts, Action) ->
    {Ts, Action}.

get_action({_Ts, Action}) ->
    Action.

get_interval({Ts, _}, [{TsNext, _} | _]) when TsNext >= Ts ->
    TsNext - Ts;

get_interval(_, _) ->
    5000.

%

-define(
    SAMPLE,
    "        "
    "aaabcdeeefghiiijklmnooopqrstuuuvwxyyyz"
).

random_payload(L) ->
    random_payload(L, []).

random_payload(0, Acc) ->
    Acc;

random_payload(N, Acc) ->
    S = lists:nth(random:uniform(length(?SAMPLE)), ?SAMPLE),
    random_payload(N - 1, [S | Acc]).
