%%% ====================================================================
%%% This software is copyright 2006-2014, ProcessOne.
%%%
%%% Event monitor for runtime statistics
%%%
%%% @copyright 2006-2014 ProcessOne
%%% @author Christophe Romain <christophe.romain@process-one.net>
%%%   [http://www.process-one.net/]
%%% @version {@vsn}, {@date} {@time}
%%% @end
%%% ====================================================================

-module(mod_mon).
-author('christophe.romain@process-one.net').
-behaviour(gen_mod).
-behaviour(gen_server).

-include("ejabberd.hrl").
-include("logger.hrl").
-include("jlib.hrl").
-include("ejabberd_commands.hrl").
-include("mod_mon.hrl").

-define(PROCNAME, ?MODULE).
-define(CALL_TIMEOUT, 4000).

%% module API
-export([start_link/2, start/2, stop/1]).
-export([value/2, reset/2, set/3, dump/1]).
%% sync commands
-export([flush_log/3, sync_log/1]).
%% administration commands
-export([active_counters_command/1, flush_probe_command/2]).
-export([jabs_command/1, reset_jabs_command/1]).
%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-export([info/1]).

%% handled ejabberd hooks
-export([
         offline_message_hook/3,
         resend_offline_messages_hook/3,
         sm_register_connection_hook/3,
         sm_remove_connection_hook/3,
         roster_in_subscription/6,
         roster_out_subscription/4,
         user_available_hook/1,
         unset_presence_hook/4,
         set_presence_hook/4,
         user_send_packet/4,
         user_receive_packet/5,
         s2s_send_packet/3,
         s2s_receive_packet/3,
         remove_user/2,
         register_user/2,
         backend_api_call/3,
         backend_api_response_time/4,
         backend_api_timeout/3,
         backend_api_error/3,
         %muc_create/4,
         %muc_destroy/3,
         %muc_user_join/4,
         %muc_user_leave/4,
         %muc_message/6,
         pubsub_create_node/5,
         pubsub_delete_node/4,
         pubsub_publish_item/6 ]).
         %pubsub_broadcast_stanza/4 ]).

% dictionary command overrided for better control
-compile({no_auto_import, [get/1]}).

-record(mon, {probe, value}).
-record(state, {host, active_count, backends, monitors, log, timers=[]}).

%%====================================================================
%% API
%%====================================================================

start_link(Host, Opts) ->
    Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
    gen_server:start_link({local, Proc}, ?MODULE, [Host, Opts], []).

start(Host, Opts) ->
    Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
    ChildSpec = {Proc, {?MODULE, start_link, [Host, Opts]},
                 temporary, 1000, worker, [?MODULE]},
    supervisor:start_child(ejabberd_sup, ChildSpec).

stop(Host) ->
    Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
    gen_server:call(Proc, stop),
    supervisor:terminate_child(ejabberd_sup, Proc),
    supervisor:delete_child(ejabberd_sup, Proc).

value(Host, Probe) when is_binary(Host), is_atom(Probe) ->
    Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
    gen_server:call(Proc, {get, Probe}, ?CALL_TIMEOUT).

set(Host, Probe, Value) when is_binary(Host), is_atom(Probe) ->
    Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
    gen_server:cast(Proc, {set, Probe, Value}).

reset(Host, Probe) when is_binary(Host), is_atom(Probe) ->
    Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
    gen_server:call(Proc, {reset, Probe}).

dump(Host) when is_binary(Host) ->
    Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
    gen_server:call(Proc, dump, ?CALL_TIMEOUT).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init([Host, Opts]) ->
    % List enabled monitors, defaults all
    Monitors = gen_mod:get_opt(monitors, Opts,
                               fun(L) when is_list(L) -> L end, [])
               ++ ?DEFAULT_MONITORS,
    % Active users counting uses hyperloglog structures
    ActiveCount = gen_mod:get_opt(active_count, Opts,
                                  fun(A) when is_atom(A) -> A end, true)
                  and not ejabberd_auth_anonymous:allow_anonymous(Host),
    Log = init_log(Host, ActiveCount),

    % Statistics backends
    BackendsSpec = gen_mod:get_opt(backends, Opts,
                                   fun(List) when is_list(List) -> List
                                   end, []),
    Backends = lists:usort([init_backend(Host, Spec)
                            || Spec <- lists:flatten(BackendsSpec)]),

    %% Note: we use priority of 20 cause some modules can block execution of hooks
    %% example; mod_offline stops the hook if it stores packets
    %Components = [Dom || Dom <- mnesia:dirty_all_keys(route),
    %                     lists:suffix(
    %                        str:tokens(Dom, <<".">>),
    %                        str:tokens(Host, <<".">>))],
    [ejabberd_hooks:add(Hook, Component, ?MODULE, Hook, 20)
     || Component <- [Host], % Todo, Components for muc and pubsub
        Hook <- ?SUPPORTED_HOOKS],
    ejabberd_commands:register_commands(commands()),

    % Start timers for cache and backends sync
    {ok, T1} = timer:apply_interval(?HOUR, ?MODULE, sync_log, [Host]),
    {ok, T2} = timer:send_interval(?MINUTE, push),

    {ok, #state{host = Host,
                active_count = ActiveCount,
                backends = Backends,
                monitors = Monitors,
                log = Log,
                timers = [T1,T2]}}.

handle_call({get, log}, _From, State) ->
    {reply, State#state.log, State};
handle_call({get, Probe}, _From, State) ->
    {reply, get(Probe), State};
handle_call({reset, Probe}, _From, State) ->
    OldVal = get(Probe),
    IsLog = State#state.active_count andalso lists:member(Probe, ?HYPERLOGLOGS),
    [put(Probe, 0) || OldVal =/= 0],
    [flush_log(State#state.host, Probe) || IsLog],
    {reply, OldVal, State};
handle_call(dump, _From, State) ->
    {reply, get(), State};
handle_call(stop, _From, State) ->
    {stop, normal, ok, State}.

handle_cast({inc, Probe}, State) ->
    Old = get(Probe),
    put(Probe, Old+1),
    {noreply, State};
handle_cast({inc, Probe, Value}, State) ->
    Old = get(Probe),
    put(Probe, Old+Value),
    {noreply, State};
handle_cast({dec, Probe}, State) ->
    Old = get(Probe),
    put(Probe, Old-1),
    {noreply, State};
handle_cast({dec, Probe, Value}, State) ->
    Old = get(Probe),
    put(Probe, Old-Value),
    {noreply, State};
handle_cast({set, log, Value}, State) ->
    {noreply, State#state{log = Value}};
handle_cast({set, Probe, Value}, State) ->
    put(Probe, Value),
    {noreply, State};
handle_cast({active, Item}, State) ->
    Log = case State#state.active_count of
        true -> ehyperloglog:update(Item, State#state.log);
        false -> State#state.log
    end,
    {noreply, State#state{log = Log}};
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(push, State) ->
    run_monitors(State#state.host, State#state.monitors),
    Probes = [{Key, Val} || {Key, Val} <- get(),
                            is_integer(Val) and not proplists:is_defined(Key, ?JABS)], %% TODO really not sync JABS ?
    [push(State#state.host, Probes, Backend) || Backend <- State#state.backends],
    [put(Key, 0) || {Key, _} <- Probes,
                    not lists:member(Key, ?NO_COUNTER_PROBES)],
    {noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, State) ->
    Host = State#state.host,
    [timer:cancel(T) || T <- State#state.timers],
    [ejabberd_hooks:delete(Hook, Host, ?MODULE, Hook, 20)
     || Hook <- ?SUPPORTED_HOOKS],
    sync_log(Host),
    ejabberd_commands:unregister_commands(commands()).

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%====================================================================
%% ejabberd commands
%%====================================================================

commands() ->
    [#ejabberd_commands{name = active_counters,
                        tags = [stats],
                        desc = "Returns active users counter in time period (daily_active_users, weekly_active_users, monthly_active_users)",
                        module = ?MODULE, function = active_counters_command,
                        args = [{host, binary}],
                        args_desc = ["Name of host which should return counters"],
                        result = {counters, {list, {counter, {tuple, [{name, string}, {value, integer}]}}}},
                        result_desc = "List of counter names with value",
                        args_example = [<<"xmpp.example.org">>],
                        result_example = [{<<"daily_active_users">>, 100},
                                          {<<"weekly_active_users">>, 1000},
                                          {<<"monthly_active_users">>, 10000}]
                       },
     #ejabberd_commands{name = flush_probe,
                        tags = [stats],
                        desc = "Returns last value from probe and resets its historical data. Supported probes so far: daily_active_users, weekly_active_users, monthly_active_users",
                        module = ?MODULE, function = flush_probe_command,
                        args = [{server, binary}, {probe_name, binary}],
                        result = {probe_value, integer}},
     #ejabberd_commands{name = jabs,
                        tags = [stats],
                        desc = "Returns the current value of jabs counter",
                        module = ?MODULE, function = jabs_command,
                        args = [{server, binary}],
                        result = {probe_value, integer}},
     #ejabberd_commands{name = reset_jabs,
                        tags = [stats],
                        desc = "Reset all jabs counters, should be called every month",
                        module = ?MODULE, function = reset_jabs_command,
                        args = [{server, binary}],
                        result = {probe_value, integer}}].

active_counters_command(Host) ->
    [{atom_to_binary(Key, latin1), Val}
     || {Key, Val} <- dump(Host),
        lists:member(Key, ?HYPERLOGLOGS)].

flush_probe_command(Host, Probe) ->
    case reset(Host, jlib:binary_to_atom(Probe)) of
        N when is_integer(N) -> N;
        _ -> 0
    end.

jabs_command(Host) ->
    [{atom_to_binary(Key, latin1), Val}
     || {Key, Val} <- jabs(Host)].

reset_jabs_command(Host) ->
    reset_jabs(Host),
    0.

%%====================================================================
%% Helper functions
%%====================================================================

hookid(Name) when is_binary(Name) -> binary_to_atom(Name, latin1);
hookid(Name) when is_atom(Name) -> Name.

packet(Main, Name, <<>>) -> <<Name/binary, "_", Main/binary, "_packet">>;
packet(Main, _Name, Type) -> <<Type/binary, "_", Main/binary, "_packet">>.

concat(Pre, <<>>) -> Pre;
concat(Pre, Post) -> <<Pre/binary, "_", Post/binary>>.

%serverhost(Host) ->
%    Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
%    case whereis(Proc) of
%        undefined ->
%            case str:chr(Host, $.) of
%                0 -> {undefined, <<>>};
%                P -> serverhost(str:substr(Host, P+1))
%            end;
%        _ ->
%            {Proc, Host}
%    end.

cast(Host, Msg) ->
    Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
    gen_server:cast(Proc, Msg).
%    case serverhost(Host) of
%        {undefined, _} -> error;
%        {Proc, _Host} -> gen_server:cast(Proc, Msg)
%    end.

%put(Key, Val) already uses erlang:put(Key, Val)
%get() already uses erlang:get()
get(Key) ->
    case erlang:get(Key) of
        undefined -> 0;
        Val -> Val
    end.

%%====================================================================
%% database api
%%====================================================================

%% this is a temporary solution, waiting for a better one, to get table size

% db_mnesia_to_sql(roster) -> <<"rosterusers">>;
% db_mnesia_to_sql(offline_msg) -> <<"spool">>;
% db_mnesia_to_sql(passwd) -> <<"users">>;
% db_mnesia_to_sql(Table) -> jlib:atom_to_binary(Table).
% 
% db_table_size(passwd) ->
%     lists:foldl(fun(Host, Acc) ->
%                         Acc + ejabberd_auth:get_vh_registered_users_number(Host)
%                 end, 0, ejabberd_config:get_global_option(hosts, fun(V) when is_list(V) -> V end));
% db_table_size(Table) ->
%     [ModName|_] = str:tokens(jlib:atom_to_binary(Table), <<"_">>),
%     Module = jlib:binary_to_atom(<<"mod_",ModName/binary>>),
%     SqlTableSize = lists:foldl(fun(Host, Acc) ->
%                                        case gen_mod:is_loaded(Host, Module) of
%                                            true -> Acc + db_table_size(Table, Host);
%                                            false -> Acc
%                                        end
%                                end, 0, ejabberd_config:get_global_option(hosts, fun(V) when is_list(V) -> V end)),
%     Info = mnesia:table_info(Table, all),
%     case proplists:get_value(local_content, Info) of
%         true -> proplists:get_value(size, Info) + other_nodes_db_size(Table) + SqlTableSize;
%         false -> proplists:get_value(size, Info) + SqlTableSize
%     end.
% 
% db_table_size(session, _Host) ->
%     0;
% db_table_size(s2s, _Host) ->
%     0;
% db_table_size(Table, Host) ->
%     %% TODO (for MySQL):
%     %% Query = [<<"select table_rows from information_schema.tables where table_name='">>,
%     %%          db_mnesia_to_sql(Table), <<"'">>];
%     %% can use odbc_queries:count_records_where(Host, db_mnesia_to_sql(Table), <<>>)
%     Query = [<<"select count(*) from ">>, db_mnesia_to_sql(Table)],
%     case catch ejabberd_odbc:sql_query(Host, Query) of
%         {selected, [_], [[V]]} ->
%             case catch jlib:binary_to_integer(V) of
%                 {'EXIT', _} -> 0;
%                 Int -> Int
%             end;
%         _ ->
%             0
%     end.
% 
% %% calculates table size on cluster excluding current node
% other_nodes_db_size(Table) ->
%     lists:foldl(fun(Node, Acc) ->
%                     Acc + rpc:call(Node, mnesia, table_info, [Table, size])
%                 end, 0, lists:delete(node(), ejabberd_cluster:get_nodes())).

%%====================================================================
%% Hooks handlers
%%====================================================================

offline_message_hook(_From, #jid{lserver=LServer}, _Packet) ->
    cast(LServer, {inc, offline_message}).
resend_offline_messages_hook(Ls, _User, Server) ->
    cast(jlib:nameprep(Server), {inc, resend_offline_messages}),
    Ls.

sm_register_connection_hook(_SID, #jid{luser=LUser,lserver=LServer,lresource=LResource}, Info) ->
    Post = case proplists:get_value(conn, Info) of
        undefined -> <<>>;
        Atom -> atom_to_binary(Atom, latin1)
    end,
    Hook = hookid(concat(<<"sm_register_connection">>, Post)),
    cast(LServer, {inc, Hook}),
    Item = <<LUser/binary, LResource/binary>>,
    cast(LServer, {active, Item}).
sm_remove_connection_hook(_SID, #jid{lserver=LServer}, Info) ->
    Post = case proplists:get_value(conn, Info) of
        undefined -> <<>>;
        Atom -> atom_to_binary(Atom, latin1)
    end,
    Hook = hookid(concat(<<"sm_remove_connection">>, Post)),
    cast(LServer, {inc, Hook}).

roster_in_subscription(Ls, _User, Server, _To, _Type, _Reason) ->
    cast(jlib:nameprep(Server), {inc, roster_in_subscription}),
    Ls.
roster_out_subscription(_User, Server, _To, _Type) ->
    cast(jlib:nameprep(Server), {inc, roster_out_subscription}).

user_available_hook(#jid{lserver=LServer}) ->
    cast(LServer, {inc, user_available_hook}).
unset_presence_hook(_User, Server, _Resource, _Status) ->
    cast(jlib:nameprep(Server), {inc, unset_presence_hook}).
set_presence_hook(_User, Server, _Resource, _Presence) ->
    cast(jlib:nameprep(Server), {inc, set_presence_hook}).

user_send_packet(#xmlel{name=Name, attrs=Attrs} = Packet,
                 _C2SState, #jid{lserver=LServer}, _To) ->
    Type = xml:get_attr_s(<<"type">>, Attrs),
    Hook = hookid(packet(<<"receive">>, Name, Type)), % user send = server receive
    cast(LServer, {inc, Hook}),
    Size = erlang:external_size(Packet),
    cast(LServer, {inc, 'XPS', 1+(Size div 6000)}),
    Packet.
user_receive_packet(#xmlel{name=Name, attrs=Attrs} = Packet,
                    _C2SState, _JID, _From, #jid{lserver=LServer}) ->
    Type = xml:get_attr_s(<<"type">>, Attrs),
    Hook = hookid(packet(<<"send">>, Name, Type)), % user receive = server send
    cast(LServer, {inc, Hook}),
    Packet.

s2s_send_packet(#jid{lserver=LServer}, _To,
                #xmlel{name=Name, attrs=Attrs}) ->
    Type = xml:get_attr_s(<<"type">>, Attrs),
    Hook = hookid(concat(<<"s2s">>, packet(<<"send">>, Name, Type))),
    cast(LServer, {inc, Hook}).
s2s_receive_packet(_From, #jid{lserver=LServer},
                   #xmlel{name=Name, attrs=Attrs}) ->
    Type = xml:get_attr_s(<<"type">>, Attrs),
    Hook = hookid(concat(<<"s2s">>, packet(<<"receive">>, Name, Type))),
    cast(LServer, {inc, Hook}).

backend_api_call(LServer, _Method, _Path) ->
    cast(LServer, {inc, backend_api_call}).
backend_api_response_time(LServer, _Method, _Path, Ms) ->
    cast(LServer, {set, backend_api_response_time, Ms}).
backend_api_timeout(LServer, _Method, _Path) ->
    cast(LServer, {inc, backend_api_timeout}).
backend_api_error(LServer, _Method, _Path) ->
    cast(LServer, {inc, backend_api_error}).

remove_user(_User, Server) ->
    cast(jlib:nameprep(Server), {inc, remove_user}).
register_user(_User, Server) ->
    cast(jlib:nameprep(Server), {inc, register_user}).

%muc_create(_Host, ServerHost, _Room, _JID) ->
%    cast(ServerHost, {inc, muc_rooms}),
%    cast(ServerHost, {inc, muc_create}).
%muc_destroy(_Host, ServerHost, _Room) ->
%    cast(ServerHost, {dec, muc_rooms}),
%    cast(ServerHost, {inc, muc_destroy}).
%muc_user_join(_Host, ServerHost, _Room, _JID) ->
%    cast(ServerHost, {inc, muc_users}),
%    cast(ServerHost, {inc, muc_user_join}).
%muc_user_leave(_Host, ServerHost, _Room, _JID) ->
%    cast(ServerHost, {dec, muc_users}),
%    cast(ServerHost, {inc, muc_user_leave}).
%muc_message(_Host, ServerHost, Room, _JID) ->
%    cast(ServerHost, {inc, {muc_message, Room}}).
%
pubsub_create_node(ServerHost, _Host, _Node, _Nidx, _NodeOptions) ->
    cast(ServerHost, {inc, pubsub_create_node}).
pubsub_delete_node(ServerHost, _Host, _Node, _Nidx) ->
    cast(ServerHost, {inc, pubsub_delete_node}).
pubsub_publish_item(ServerHost, _Node, _Publisher, _From, _ItemId, _Packet) ->
    %Size = erlang:external_size(Packet),
    cast(ServerHost, {inc, pubsub_publish_item}).
%pubsub_broadcast_stanza(Host, Node, Count, _Stanza) ->
%    cast(Host, {inc, {pubsub_broadcast_stanza, Node, Count}}).

%%====================================================================
%% active user feature
%%====================================================================

% HyperLogLog notes:
% Let σ ≈ 1.04/√m represent the standard error; the estimates provided by HYPERLOGLOG
% are expected to be within σ, 2σ, 3σ of the exact count in respectively 65%, 95%, 99%
% of all the cases.
%
% bits / memory / registers / σ 2σ 3σ
% 10   1309  1024 ±3.25% ±6.50% ±9.75%
% 11   2845  2048 ±2.30% ±4.60% ±6.90%
% 12   6173  4096 ±1.62% ±3.26% ±4.89%
% 13  13341  8192 ±1.15% ±2.30% ±3.45%
% 14  28701 16384 ±0.81% ±1.62% ±2.43%
% 15  62469 32768 ±0.57% ±1.14% ±1.71%
% 16 131101 65536 ±0.40% ±0.81% ±1.23%   <=== we take this one

init_log(_Host, false) ->
    undefined;
init_log(Host, true) ->
    case read_logs(Host) of
        [] ->
            L = ehyperloglog:new(16),
            write_logs(Host, [{Key, L} || Key <- ?HYPERLOGLOGS]),
            [put(Key, 0) || Key <- ?HYPERLOGLOGS],
            L;
        Logs ->
            [put(Key, round(ehyperloglog:cardinality(Val))) || {Key, Val} <- Logs],
            proplists:get_value(hd(?HYPERLOGLOGS), Logs)
    end.

cluster_log(Host, Nodes) ->
    case rpc:multicall(Nodes, ?MODULE, value, [Host, log], 8000) of
        {Success, _Fail} ->
            [Log|Logs] = [L || L <- Success, L =/= error],
            lists:foldl(fun(Remote, Acc) when is_atom(Remote) -> Acc;
                           (Remote, Acc) -> ehyperloglog:merge(Acc, Remote)
                        end, Log, Logs);
        _ ->
            undefined
    end.

sync_log(Host) when is_binary(Host) ->
    % this process can safely run on its own, thanks to put/get hyperloglogs not using dictionary
    % it should be called at regular interval to keep logs consistency
    % as timer is handled by main process handling the loop, we spawn here to not interfere with the loop
    spawn(fun() ->
                Nodes = ejabberd_cluster:get_nodes(),
                case cluster_log(Host, Nodes) of
                    Error when is_atom(Error) ->
                        Error;
                    ClusterLog ->
                        set(Host, log, ClusterLog),
                        write_logs(Host, [merge_log(Host, Key, Val, ClusterLog)
                                          || {Key, Val} <- read_logs(Host)])
                end
        end).

flush_log(Host, Probe) ->
    % this process can safely run on its own, thanks to put/get hyperloglogs not using dictionary
    % it may be called at regular interval with timers or external cron
    spawn(fun() ->
                Nodes = ejabberd_cluster:get_nodes(),
                case cluster_log(Host, Nodes) of
                    Error when is_atom(Error) ->
                        Error;
                    ClusterLog ->
                        rpc:multicall(Nodes, ?MODULE, flush_log, [Host, Probe, ClusterLog])
                end
        end).
flush_log(Host, Probe, ClusterLog) when is_binary(Host), is_atom(Probe) ->
    set(Host, log, ehyperloglog:new(16)),
    {UpdatedLogs, _} = lists:foldr(
            fun({Key, Val}, {Acc, Continue}) ->
                    Keep = Continue and (Key =/= Probe),
                    NewLog = case Keep of
                        true -> merge_log(Host, Key, Val, ClusterLog);
                        false -> reset_log(Host, Key)
                    end,
                    {[NewLog|Acc], Keep}
            end,
            {[], true}, read_logs(Host)),
    write_logs(Host, UpdatedLogs).

merge_log(Host, Probe, Log, ClusterLog) ->
    Merge = ehyperloglog:merge(ClusterLog, Log),
    set(Host, Probe, round(ehyperloglog:cardinality(Merge))),
    {Probe, Merge}.

reset_log(Host, Probe) ->
    set(Host, Probe, 0),
    {Probe, ehyperloglog:new(16)}.

write_logs(Host, Logs) when is_list(Logs) ->
    File = logfilename(Host),
    filelib:ensure_dir(File),
    file:write_file(File, term_to_binary(Logs)).

read_logs(Host) ->
    File = logfilename(Host),
    case file:read_file(File) of
        {ok, Bin} ->
            case catch binary_to_term(Bin) of
                List when is_list(List) ->
                    % prevent any garbage loading
                    lists:filter(
                        fun({Key, _Val}) -> lists:member(Key, ?HYPERLOGLOGS);
                           (_) -> false
                        end,
                        List);
                _ ->
                    []
            end;
        _ ->
            []
    end.

logfilename(Host) when is_binary(Host) ->
    Name = binary:replace(Host, <<".">>, <<"_">>, [global]),
    filename:join([mnesia:system_info(directory), "hyperloglog", <<Name/binary, ".bin">>]).

%%====================================================================
%% high level monitors
%%====================================================================

run_monitors(_Host, Monitors) ->
    Probes = [{Key, Val} || {Key, Val} <- get(), is_integer(Val)],
    lists:foreach(
        fun({I, M, F, A}) -> put(I, apply(M, F, A));
           ({I, M, F, A, Fun}) -> put(I, Fun(apply(M, F, A)));
           ({I, Spec}) -> put(I, eval_monitors(Probes, Spec, 0));
           (_) -> ok
        end, Monitors).

eval_monitors(_, [], Acc) ->
    Acc;
eval_monitors(Probes, [Action|Tail], Acc) ->
    eval_monitors(Probes, Tail, compute_monitor(Probes, Action, Acc)).

compute_monitor(Probes, Probe, Acc) when is_atom(Probe) ->
    compute_monitor(Probes, {'+', Probe}, Acc);
compute_monitor(Probes, {'+', Probe}, Acc) ->
    case proplists:get_value(Probe, Probes) of
        undefined -> Acc;
        Val -> Acc+Val
    end;
compute_monitor(Probes, {'-', Probe}, Acc) ->
    case proplists:get_value(Probe, Probes) of
        undefined -> Acc;
        Val -> Acc-Val
    end.

%%====================================================================
%% Cache sync
%%====================================================================

init_backend(Host, {statsd, Server}) ->
    application:load(statsderl),
    application:set_env(statsderl, base_key, binary_to_list(Host)),
    case catch inet:getaddr(binary_to_list(Server), inet) of
        {ok, Ip} -> application:set_env(statsderl, hostname, Ip);
        _ -> ?WARNING_MSG("statsd have undefined endpoint: can not resolve ~p", [Server])
    end,
    application:start(statsderl),
    statsd;
init_backend(Host, statsd) ->
    application:load(statsderl),
    application:set_env(statsderl, base_key, binary_to_list(Host)),
    application:start(statsderl),
    statsd;
init_backend(Host, mnesia) ->
    Table = gen_mod:get_module_proc(Host, mon),
    mnesia:create_table(Table,
                        [{disc_copies, [node()]},
                         {local_content, true},
                         {record_name, mon},
                         {attributes, record_info(fields, mon)}]),
    mnesia;
init_backend(_, _) ->
    none.

push(Host, Probes, mnesia) ->
    Table = gen_mod:get_module_proc(Host, mon),
    Cache = [{Key, Val} || {mon, Key, Val} <- ets:tab2list(Table)],
    lists:foreach(
        fun({Key, Val}) ->
                case proplists:get_value(Key, ?NO_COUNTER_PROBES) of
                    undefined ->
                        case proplists:get_value(Key, Cache) of
                            undefined -> mnesia:dirty_write(Table, #mon{probe = Key, value = Val});
                            Old -> [mnesia:dirty_write(Table, #mon{probe = Key, value = Old+Val}) || Val > 0]
                        end;
                    gauge ->
                        case proplists:get_value(Key, Cache) of
                            Val -> ok;
                            _ -> mnesia:dirty_write(Table, #mon{probe = Key, value = Val})
                        end;
                    _ ->
                        ok
                end
        end, Probes);
push(_Host, Probes, statsd) ->
    % Librato metrics are name first with service name (to group the metrics from a service),
    % then type of service (xmpp, etc) and then name of the data itself
    % example => process-one.net.xmpp.xmpp-1.chat_receive_packet
    [_, NodeId] = str:tokens(atom_to_binary(node(), latin1), <<"@">>),
    [Node | _] = str:tokens(NodeId, <<".">>),
    BaseId = <<"xmpp.", Node/binary>>,
    lists:foreach(
        fun({Key, Val}) ->
                Id = <<BaseId/binary, ".", (atom_to_binary(Key, latin1))/binary>>,
                case proplists:get_value(Key, ?NO_COUNTER_PROBES) of
                    undefined -> statsderl:increment(Id, Val, 1);
                    gauge -> statsderl:gauge(Id, Val, 1);
                    _ -> ok
                end
        end, Probes);
push(_Host, _Probes, none) ->
    ok.

%%====================================================================
%% JABS api
%%====================================================================

% TODO put this on gen_server instead, to avoid need of mnesia
% or create a dedicated jabs table for persistence cause actually
% it works only with mnesia backend
jabs(Host) ->
    Table = gen_mod:get_module_proc(Host, mon),
    ets:foldl(fun(Mon, Acc) ->
                case proplists:get_value(Mon#mon.probe, ?JABS) of
                    undefined -> Acc;
                    Weight -> [{Mon#mon.probe, Mon#mon.value*Weight}|Acc]
                end
        end, [], Table).

reset_jabs(Host) ->
    Table = gen_mod:get_module_proc(Host, mon),
    [mnesia:dirty_write(Table, Mon#mon{value = 0})
     || Mon <- ets:tab2list(Table),
        proplists:is_defined(Mon#mon.probe, ?JABS)].


%%====================================================================
%% Temporary helper to get clear cluster view ov most important probes
%%====================================================================

merge_sets([L]) -> L;
merge_sets([L1,L2]) -> merge_set(L1,L2);
merge_sets([L1,L2|Tail]) -> merge_sets([merge_set(L1,L2)|Tail]).
merge_set(L1, L2) ->
    lists:foldl(fun({K,V}, Acc) ->
                case proplists:get_value(K, Acc) of
                    undefined -> [{K,V}|Acc];
                    Old -> lists:keyreplace(K, 1, Acc, {K,Old+V})
                end
        end, L1, L2).

tab2set(Mons) when is_list(Mons) ->
    [{K,V} || {mon,K,V} <- Mons];
tab2set(_) ->
    [].

info(Host) when is_binary(Host) ->
    Table = gen_mod:get_module_proc(Host, mon),
    Probes = merge_sets([tab2set(rpc:call(Node, ets, tab2list, [Table])) || Node <- ejabberd_cluster:get_nodes()]),
    [{Key, Val} || {Key, Val} <- Probes,
                   lists:member(Key, [c2s_receive, c2s_send, s2s_receive, s2s_send])].
