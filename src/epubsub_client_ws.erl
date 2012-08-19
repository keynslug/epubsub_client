%
% EPubSub single websocket client.
%

-module(epubsub_client_ws).
-behaviour(gen_fsm).

-include("epubsub_client_logger.hrl").
-include("wsecli.hrl").

%% API
-export([
    start_link/2,
    stop/1,
    send/2
]).

%% Callbacks
-export([
    closing/2,
    online/2,
    offline/2
]).

-export([
    init/1,
    handle_event/3,
    handle_sync_event/4,
    handle_info/3,
    terminate/3,
    code_change/4
]).

-define(TCPOPTS, [binary, {packet, raw}, {active, true}]).
-define(CLOSE_HANDSHAKE_TIMEOUT, 2000).
-define(TCP_CLOSE_TIMEOUT, 500).

%% State
-record(state, {
    id,
    socket,
    handshake :: #handshake{},
    fragmented = undefined :: #message{}
}).

%%

start_link(Endpoint, ID) ->
    gen_fsm:start_link(?MODULE, [Endpoint, ID], []).

stop(Pid) ->
    gen_fsm:send_event(Pid, stop).

send(Pid, Message) ->
    gen_fsm:send_event(Pid, {send, Message}).

%%

init([{Host, Port, Path}, ID]) ->

    process_flag(trap_exit, true),

    ?LOG_DEBUG("[~p] Connecting to ws://~s:~p~s", [ID, Host, Port, Path]),
    case gen_tcp:connect(Host, Port, ?TCPOPTS) of

        {ok, Socket} ->
            Handshake = wsecli_handshake:build(Path, Host, Port),
            Request = wsecli_http:to_request(Handshake#handshake.message),
            ok = gen_tcp:send(Socket, Request),
            {ok, offline, #state{id = ID, socket = Socket, handshake = Handshake}, hibernate};

        Error = {error, Reason} ->
            ?LOG_ERROR("[~p] Connection failed with ~p", [ID, Reason]),
            {stop, Error}

    end.

closing({send, Message}, StateData) ->
    ?LOG_WARN("[~p] Connection is in closing state", [StateData#state.id]),
    {next_state, closing, StateData, hibernate};

closing({timeout, _Ref, waiting_tcp_close}, StateData) ->
    ?LOG_WARN("[~p] Connection close timed out", [StateData#state.id]),
    {stop, normal, close(StateData)};

closing({timeout, _Ref, waiting_close_reply}, StateData) ->
    ?LOG_WARN("[~p] Close reply timed out", [StateData#state.id]),
    {stop, normal, close(StateData)};

closing(stop, State) ->
    {next_state, closing, State, hubernate}.

online({send, Data}, StateData) ->
    ?LOG_DEBUG("[~p] Sending message: ~s", [StateData#state.id, Data]),
    Message = wsecli_message:encode(Data, text),
    case gen_tcp:send(StateData#state.socket, Message) of
        ok -> 
            {next_state, online, StateData, hibernate};
        Error ->
            ?LOG_ERROR("[~p] Sending message failed due to ~p", [StateData#state.id, Error]),
            {stop, Error, StateData}
    end;

online(stop, StateData) ->
    ?LOG_DEBUG("[~p] Sending close packet", [StateData#state.id]),
    Message = wsecli_message:encode([], close),
    case gen_tcp:send(StateData#state.socket, Message) of
        ok ->
            gen_fsm:start_timer(?CLOSE_HANDSHAKE_TIMEOUT, waiting_close_reply),
            {next_state, closing, StateData, hibernate};
        Error = {error, Reason} ->
            ?LOG_ERROR("[~p] Sending close packet failed with ~p", [StateData#state.id, Reason]),
            {stop, Error, StateData}
    end.

offline({send, Message}, StateData) ->
    ?LOG_WARN("[~p] Connection is offline", [StateData#state.id]),
    {next_state, offline, StateData, hibernate};

offline(stop, State) ->
    {stop, shutdown, close(State)}.

handle_event(_Event, StateName, State) ->
    {next_state, StateName, State, hibernate}.

handle_sync_event(_Event, _From, StateName, State) ->
    {next_state, StateName, State, hibernate}.

%% Handshake

handle_info({tcp, _Socket, Data}, offline, State) ->
    ?LOG_DEBUG("[~p] Received handshake", [State#state.id]),
    Response = wsecli_http:from_response(Data),
    try wsecli_handshake:validate(Response, State#state.handshake) of
        true ->
            ?LOG_DEBUG("[~p] Handshake ok", [State#state.id]),
            {next_state, online, State, hibernate};
        false ->
            ?LOG_ERROR("[~p] Handshake failed", [State#state.id]),
            {stop, {error, handshake_failed}, State}
    catch _:Reason ->
        ?LOG_ERROR("[~p] Handshake validation failed due to ~p", [State#state.id, Reason]),
        {stop, {error, connect_failed}, close(State)}
    end;

%% Handshake complete, handle packets

handle_info({tcp, _Socket, RawData}, online, StateData) ->
    {Messages, State} = case StateData#state.fragmented of
        undefined ->
            {wsecli_message:decode(RawData), StateData};
        Message ->
            {wsecli_message:decode(RawData, Message), StateData#state{fragmented = undefined}}
    end,
    FinalStateData = process_messages(Messages, State),
    {next_state, online, FinalStateData, hibernate};

handle_info({tcp, _Socket, RawData}, closing, StateData) ->
    Message = lists:last(wsecli_message:decode(RawData)),
    case Message#message.type of
        close ->
            gen_fsm:start_timer(?TCP_CLOSE_TIMEOUT, waiting_tcp_close),
            {next_state, closing, StateData, hibernate};
        _ ->
            {next_state, closing, StateData, hibernate}
    end;

handle_info({tcp_closed, _Socket}, closing, State) ->
    ?LOG_DEBUG("[~p] Connection closed gracefully", [State#state.id]),
    {stop, shutdown, State#state{socket = undefined}};

handle_info({tcp_closed, _Socket}, _StateName, State) ->
    ?LOG_ERROR("[~p] Connection closed unexpectedly", [State#state.id]),
    {stop, {error, unexpected_shutdown}, State#state{socket = undefined}};

handle_info({tcp_error, _Socket, Reason}, _StateName, State) ->
    ?LOG_ERROR("[~p] Connection closed with reason ~p", [State#state.id, Reason]),
    {stop, {error, Reason}, close(State)};

handle_info({'EXIT', Pid, _Reason}, StateName, State) ->
    ?LOG_DEBUG("[~p] Received exit signal from ~p", [State#state.id, Pid]),
    {next_state, StateName, State, hibernate};

handle_info(Packet, offline, State) ->
    ?LOG_ERROR("[~p] Received packet in offline state: ~p", [State#state.id, Packet]),
    {stop, {error, bad_state}, State}.

terminate(Reason, _StateName, State) ->
    ?LOG_DEBUG("[~p] Terminated with reason ~p", [State#state.id, Reason]),
    ok.

code_change(_OldVsn, StateName, State, _Extra) ->
    {ok, StateName, State}.

%% Internal functions

close(State = #state{socket = undefied}) ->
    State;

close(State = #state{socket = Socket}) ->
    gen_tcp:close(Socket),
    State#state{socket = undefined}.

process_messages([], StateData) ->
    StateData;

process_messages([Message | Messages], StateData) ->
    case Message#message.type of
        text ->
            ?LOG_DEBUG("[~p] Received text message with payload: ~s", [StateData#state.id, Message#message.payload]),
            process_messages(Messages, StateData);
        binary ->
            ?LOG_DEBUG("[~p] Received binary message with payload: ~s", [StateData#state.id, Message#message.payload]),
            process_messages(Messages, StateData);
        fragmented ->
            ?LOG_DEBUG("[~p] Received partial message", [StateData#state.id]),
            NewStateData = StateData#state{fragmented = Message},
            process_messages(Messages, NewStateData)
    end.
