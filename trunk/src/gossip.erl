%  @copyright 2010-2014 Zuse Institute Berlin

%   Licensed under the Apache License, Version 2.0 (the "License");
%   you may not use this file except in compliance with the License.
%   You may obtain a copy of the License at
%
%       http://www.apache.org/licenses/LICENSE-2.0
%
%   Unless required by applicable law or agreed to in writing, software
%   distributed under the License is distributed on an "AS IS" BASIS,
%   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%   See the License for the specific language governing permissions and
%   limitations under the License.

%% @author Jens V. Fischer <jensvfischer@gmail.com>
%%
%% @doc The behaviour modul (gossip_beh.erl) of the gossiping framework.
%%
%%      The framework is designed to allow the implementation of gossip based
%%      dissemination and gossip based aggregation protocols. Anti-entropy
%%      gossiping was not considered. The communication scheme used by the
%%      framework is push-pull gossiping as this offers the best speed of
%%      convergence. The membership protocol used for the peer selection is
%%      Cyclon.
%%
%%      The gossiping framework comprises three kinds of components:
%%      <ol>
%%          <li> The gossiping behaviour (interface) gossip_beh.erl. The
%%               behaviour defines the contract that allows the callback module
%%               to be used by the behaviour module. The behaviour defines the
%%               contract by specifying functions the callback module has to
%%               implement. </li>
%%          <li> The callback modules. A callback module implements a concrete
%%               gossiping protocol by implementing the gossip_beh.erl, i.e. by
%%               implementing the functions specified in the gossip_beh.erl.
%%               The callback module provides the protocol specific code.
%%               For an example callback module see gossip_load.erl.</li>
%%          <li> The behaviour module gossip.erl (this module). The behaviour
%%               module provides the generic code of the gossiping  framework.
%%               It calls the callback functions of the callback modules defined
%%               in gossip_beh.erl.</li>
%%      </ol>
%%
%%      The relation between behaviour and callback modules is modelled as a
%%      one-to-many relation. That is to say, the behaviour module is implemented
%%      as single process (per node) and all the callback module run in the
%%      context of this single process. This has the advantage of reducing the
%%      number of spawned processes and allowing for a better grouping of messages.
%%
%%      The framework is started as part of the startup procedure of a dht_node.
%%      The framework maintains a list of callback modules in the CBMODULES macro
%%      which are started together with the framework. It is also possible to
%%      individually start and stop callback modules later.
%%
%%      The pattern for communication between the behaviour module and a callback
%%      module is the following: From the behaviour module to a callback module
%%      communication occurs as a call to a function of the callback module.
%%      These calls have to return quickly, no long-lasting operations, especially
%%      no receiving of messages, are allowed. Therefore, the answers to these
%%      function calls are mainly realised as messages from the respective
%%      callback module to the behaviour module, not as return values of the
%%      function calls.
%%
%%      == Phases of a Gossiping Operation ==
%%
%%      === Prepare-Request Phase ===
%%
%%      The  prepare-request phase consists of peer and data selection. The
%%      selection of the peer is usually managed by the framework. At the beginning
%%      of every cycle the behaviour module requests a peer from the Cyclon
%%      module of Scalaris, which is then used for the data exchange. The peer
%%      selection is governed by the select_node() function: returning
%%      false causes the behaviour module to handle the peer selection as described.
%%      Returning true causes the behaviour module to expect a selected_peer
%%      message with a peer to be used by for the exchange. How many peers are
%%      contracted for data exchanges every cycle depends on the fanout() config
%%      function.
%%
%%      The selection of the exchange data is dependent on the specific gossiping
%%      task and therefore done by a callback module. It is initiated by a call
%%      to select_data(). When called with select_data(), the respective callback
%%      module has to initiate a selected_data message to the behaviour module,
%%      containing the selected exchange data. Both peer and data selection are
%%      initiated in immediate succession through periodical trigger messages,
%%      so they can run concurrently. When both data and peer are received by
%%      the behaviour module, a p2p_exch message with the exchange data is sent
%%      to the peer, that is to say to the gossip behaviour module of the peer.
%%
%%      === Prepare-Reply Phase ===
%%
%%      Upon receiving a p2p_exch message, a node enters the prepare-reply
%%      phase and is now in its passive role as responder. This phase is about
%%      the integration of the received data and the preparation of the reply data.
%%      Both of these tasks need to be handled by the callback module. The
%%      behaviour module passes the received data with a call to select_reply_data(QData)
%%      to the correspondent callback module, which merges the data with its own
%%      local data and prepares the reply data. The reply data is sent back to
%%      the behaviour module with a selected_reply_data message. The behaviour
%%      module then sends the reply data as a  p2p_exch_reply message back to
%%      the original requester.
%%
%%      === Integrate-Reply Phase ===
%%
%%      The integrate-reply phase is triggered by a p2p_exch_reply message.
%%      Every p2p_exch_reply is the response to an earlier p2p_exch (although
%%      not necessarily to the last p2p_exch request. The p2p_exch_reply contains
%%      the reply data from the peer, which is passed to the correspondent
%%      callback module with a call to integrate_data(QData). The callback module
%%      processes the received data and signals to the behaviour module the
%%      completion with an integrated_data message. On a conceptual level, a full
%%      cycle is finished at this point and the behaviour module counts cycles
%%      by counting the \inline$integrated_§data$ messages. Due to the uncertainties
%%      of message delays and local clock drift it should be clear however, that
%%      this can only be an approximation. For instance, a new cycle could have
%%      been started before the reply to the current request has been received
%%      (phase interleaving) and, respectively, replies from the other cycle could
%%      be "wrongly" counted as finishing the current cycle (cycle interleaving).
%%
%%      == Instantiation ==
%%
%%      Many of the interactions conducted by the behaviour module are specific
%%      to a certain callback module. Therefore, all messages and function
%%      concerning a certain callback module need to identify with which callback
%%      module the message or call is associated. This is achieved by adding a
%%      tuple of the module name and an instance id to all those messages and
%%      calls. While the name would be enough to identify the module, adding the
%%      instance id allows for multiple instantiation of the same callback module
%%      by one behaviour module. This tuple of callback module and instance id
%%      is also used to store information specific to a certain callback module
%%      in the behaviour module's state.
%%
%%
%%         Used abbreviations:
%%         <ul>
%%            <li> cb: callback module (a module implementing the
%%                     gossip_beh.erl behaviour)
%%            </li>
%%         </ul>
%%
%% @version $Id$
-module(gossip).
-author('jensvfischer@gmail.com').
-vsn('$Id$').

-behaviour(gen_component).

-include("scalaris.hrl").

% interaction with gen_component
-export([init/1, on_inactive/2, on_active/2]).

%API
-export([start_link/1, activate/1, deactivate/0, start_gossip_task/2, stop_gossip_task/1, remove_all_tombstones/0, check_config/0]).

% interaction with the ring maintenance:
-export([rm_filter_slide_msg/3, rm_send_activation_msg/5, rm_my_range_changed/3, rm_send_new_range/5]).

% testing
-export([tester_create_state/9, is_state/1, tester_gossip_beh_modules/1]).

%% -define(PDB, pdb_ets). % easier debugging because state accesible from outside the process
-define(PDB_OPTIONS, [set]).
-define(PDB, pdb). % better performance

% prevent warnings in the log
-define(SEND_TO_GROUP_MEMBER(Pid, Process, Msg),
        comm:send(Pid, Msg, [{group_member, Process}, {shepherd, self()}])).

%% -define(SHOW, config:read(log_level)).
-define(SHOW, debug).

-define(CBMODULES, [{gossip_load, default}]). % callback modules as list

-define(FIRST_TRIGGER_DELAY, 10). % delay in s for first trigger


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Type Definitions
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

-type state() :: ets:tab().
-type cb_module() :: module().
-type cb_module_name() :: [{Module::cb_module(), Name::atom()}].

-type state_key_cb() :: cb_state | cb_status | cycles | trigger_lock |
                        exch_data | round.
-type state_key() :: cb_modules | msg_queue | range | status |
                     {reply_peer, pos_integer()} |
                     {trigger_group, pos_integer()} |
                     {state_key_cb(), cb_module_name()} .
-type cb_fun_name() :: get_values_all | get_values_best | handle_msg |
                       integrate_data | notify_change | round_has_converged |
                       select_data | select_node | select_reply_data |
                       web_debug_info | shutdown.

% accepted messages of gossip behaviour module

-ifdef(forward_or_recursive_types_are_not_allowed).
-type send_error() :: {send_error, _Pid::comm:mypid(), Msg::comm:message(), Reason::atom()}.
-else.
-type send_error() :: {send_error, _Pid::comm:mypid(), Msg::message(), Reason::atom()}.
-endif.

-type bh_message() ::
    {activate_gossip, Range::intervals:interval()} |
    {start_gossip_task, CBModule::cb_module_name(), Args::list()} |
    {gossip_trigger, TriggerInterval::pos_integer()} |
    {update_range, NewRange::intervals:interval()} |
    {web_debug_info, SourcePid::comm:mypid()} |
    send_error() |
    {bulkowner, deliver, Id::uid:global_uid(), Range::intervals:interval(),
        Msg::comm:message(), Parents::[comm:mypid(),...]} |
    {remove_all_tombstones}
.

-type cb_message() ::
    {selected_data, CBModule::cb_module_name(), PData::gossip_beh:exch_data()} |
    {selected_peer, CBModule::cb_module_name(), CyclonMsg::{cy_cache,
            RandomNodes::[node:node_type()]} } |
    {p2p_exch, CBModule::cb_module_name(), SourcePid::comm:mypid(),
        PData::gossip_beh:exch_data(), OtherRound::non_neg_integer()} |
    {selected_reply_data, CBModule::cb_module_name(), QData::gossip_beh:exch_data(),
        Ref::pos_integer(), Round::non_neg_integer()} |
    {p2p_exch_reply, CBModule::cb_module_name(), SourcePid::comm:mypid(),
        QData::gossip_beh:exch_data(), OtherRound::non_neg_integer()} |
    {integrated_data, CBModule::cb_module_name(), current_round} |
    {new_round, CBModule::cb_module_name(), NewRound::non_neg_integer()} |
    {cb_reply, CBModule::cb_module_name(), Msg::comm:message()} |
    {get_values_best, CBModule::cb_module_name(), SourcePid::comm:mypid()} |
    {get_values_all, CBModule::cb_module_name(), SourcePid::comm:mypid()} |
    {stop_gossip_task, CBModule::cb_module_name()} |
    no_msg
.

-type message() :: bh_message() | cb_message().

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% API
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% @doc Start the process of the gossip module. <br/>
%%      Called by sup_dht_node, calls gen_component:start_link to start the process.
-spec start_link(pid_groups:groupname()) -> {ok, pid()}.
start_link(DHTNodeGroup) ->
    gen_component:start_link(?MODULE, fun ?MODULE:on_inactive/2, [],
                             [{wait_for_init},
                              {pid_groups_join_as, DHTNodeGroup, gossip}]).


%% @doc Initialises the state of the gossip module. <br/>
%%      Called by gen_component, results in on_inactive handler.
-spec init([]) -> state().
init([]) ->
    TabName = ?PDB:new(state, ?PDB_OPTIONS),
    state_set(status, uninit, TabName),
    state_set(cb_modules, [], TabName),
    state_set(msg_queue, msg_queue:new(), TabName),
    TabName.


%% @doc Activate the gossip module. <br/>
%%      Called by dht_node_join. Activates process (when only node of the system)
%%      or subscribes to the rm to activate on slide_finished messages. <br/>
%%      Result of the activation is to switch to the on_active handler.
-spec activate(Range::intervals:interval()) -> ok.
activate(MyRange) ->
    case MyRange =:= intervals:all() of
        true ->
            % We're the first node covering the whole ring range.
            % Start gossip right away because it's needed for passive
            % load balancing when new nodes join the ring.
            comm:send_local(pid_groups:get_my(gossip), {activate_gossip, MyRange});
        _    ->
            % subscribe to ring maintenance (rm) for {slide_finished, succ} or {slide_finished, pred}
            rm_loop:subscribe(self(), ?MODULE,
                              fun gossip:rm_filter_slide_msg/3,
                              fun gossip:rm_send_activation_msg/5, 1)
    end.

%% @doc Deactivates all gossip processes.
-spec deactivate() -> ok.
deactivate() ->
    Msg = {?send_to_group_member, gossip, {deactivate_gossip}},
    bulkowner:issue_bulk_owner(uid:get_global_uid(), intervals:all(), Msg).


%% @doc Globally starts a gossip task identified by CBModule. <br/>
%%      Args is passed to the init function of the callback module. <br/>
%%      CBModule is either the name of a callback module or an name-instance_id
%%      tuple.
-spec start_gossip_task(CBModule, Args) -> ok when
    is_subtype(CBModule, cb_module() | cb_module_name() | {cb_module_name(), uid:global_uid()}),
    is_subtype(Args, list()).
start_gossip_task(ModuleName, Args) when is_atom(ModuleName) ->
    Id = uid:get_global_uid(),
    start_gossip_task({ModuleName, Id}, Args);

start_gossip_task({ModuleName, Id}, Args) when is_atom(ModuleName) ->
    Msg = {?send_to_group_member, gossip,
                {start_gossip_task, {ModuleName, Id}, Args}},
    bulkowner:issue_bulk_owner(uid:get_global_uid(), intervals:all(), Msg).


%% @doc Globally stop a gossip task.
-spec stop_gossip_task(CBModule::cb_module_name()) -> ok.
stop_gossip_task(CBModule) ->
    Msg = {?send_to_group_member, gossip, {stop_gossip_task, CBModule}},
    bulkowner:issue_bulk_owner(uid:get_global_uid(), intervals:all(), Msg).


%% @doc Globally removes all tombstones from previously stopped callback modules.
-spec remove_all_tombstones() -> ok.
remove_all_tombstones() ->
    Msg = {?send_to_group_member, gossip, {remove_all_tombstones}},
    bulkowner:issue_bulk_owner(uid:get_global_uid(), intervals:all(), Msg).


%% @doc Checks whether the received notification is a {slide_finished, succ} or
%%      {slide_finished, pred} msg. Used as filter function for the ring maintanance.
-spec rm_filter_slide_msg(Neighbors, Neighbors, Reason) -> boolean() when
                          is_subtype(Neighbors, nodelist:neighborhood()),
                          is_subtype(Reason, rm_loop:reason()).
rm_filter_slide_msg(_OldNeighbors, _NewNeighbors, Reason) ->
        Reason =:= {slide_finished, pred} orelse Reason =:= {slide_finished, succ}.

%% @doc Sends the activation message to the behaviour module (this module)
%%      Used to subscribe to the ring maintenance for {slide_finished, succ} or
%%      {slide_finished, pred} msg.
-spec rm_send_activation_msg(Subscriber, ?MODULE, Neighbours, Neighbours, Reason) -> ok when
                             is_subtype(Subscriber, pid()),
                             is_subtype(Neighbours, nodelist:neighborhood()),
                             is_subtype(Reason, rm_loop:reason()).
rm_send_activation_msg(_Pid, ?MODULE, _OldNeighbours, NewNeighbours, _Reason) ->
    %% io:format("Pid: ~w. Self: ~w. PidGossip: ~w~n", [Pid, self(), Pid2]),
    MyRange = nodelist:node_range(NewNeighbours),
    Pid = pid_groups:get_my(gossip),
    comm:send_local(Pid, {activate_gossip, MyRange}).


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Main Message Loop
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%%-------------------------- on_inactive ---------------------------%%

%% @doc Message handler during the startup of the gossip module.
-spec on_inactive(Msg::message(), State::state()) -> state().
on_inactive({activate_gossip, MyRange}=Msg, State) ->
    ?PDB:set({status, init}, State),

    % subscribe to ring maintenance (rm)
    rm_loop:subscribe(self(), ?MODULE,
                      fun gossip:rm_my_range_changed/3,
                      fun gossip:rm_send_new_range/5, inf),

    init_gossip_tasks(State),

    % set range and notify cb modules about leader state
    state_set(range, MyRange, State),
    Msg1 = case is_leader(MyRange) of
        true -> {is_leader, MyRange};
        false -> {no_leader, MyRange}
    end,
    List = [leader, Msg1],
    Fun = fun (CBModule) -> cb_call(notify_change, List, Msg, CBModule, State) end,
    CBModules = state_get(cb_modules, State),
    lists:foreach(Fun, CBModules),

    % change handler to on_active
    gen_component:change_handler(State, fun ?MODULE:on_active/2);


on_inactive({p2p_exch, _CBModule, SourcePid, _PData, _Round}=Msg, State) ->
    comm:send(SourcePid, {send_error, comm:this(), Msg, on_inactive}),
    State;


on_inactive({p2p_exch_reply, _CBModule, SourcePid, _QData, _Round}=Msg, State) ->
    comm:send(SourcePid, {send_error, comm:this(), Msg, on_inactive}),
    State;


on_inactive({get_values_best, _CBModule, _SourcePid}=Msg, State) ->
    msg_queue_add(Msg, State), State;


on_inactive({get_values_all, _CBModule, _SourcePid}=Msg, State) ->
   msg_queue_add(Msg, State), State;


on_inactive({web_debug_info, _Requestor}=Msg, State) ->
    msg_queue_add(Msg, State), State;


on_inactive({stop_gossip_task, _CBModule}=Msg, State) ->
    msg_queue_add(Msg, State), State;


on_inactive({start_gossip_task, _CBModule, _Args}=Msg, State) ->
    msg_queue_add(Msg, State), State;


on_inactive({remove_all_tombstones}=Msg, State) ->
    msg_queue_add(Msg, State), State;


on_inactive(_Msg, State) ->
    State.


%%--------------------------- on_active ----------------------------%%

%% @doc Message handler during the normal operation of the gossip module.
%% @end

%% This message is received from self() from init_gossip_task or through
%% start_gossip_task()/bulkowner
-spec on_active(Msg::message(), State::state()) -> state().
on_active({start_gossip_task, CBModule, Args}, State) ->
    CBModules = state_get(cb_modules, State),
    case contains(CBModule, CBModules) of
        true ->
            log:log(warn, "[ Gossip ] Trying to start an already existing Module: ~w ."
                ++ "Request will be ignored.", [CBModule]);
        false -> init_gossip_task(CBModule, Args, State)
    end,
    State;


%% trigger message starting a new cycle
on_active({gossip_trigger, TriggerInterval}=Msg, State) ->
    msg_queue_send(State),
    log:log(debug, "[ Gossip ] Triggered: ~w", [Msg]),
    case state_get_raw({trigger_group, TriggerInterval}, State) of
        undefined ->
            ok; %% trigger group does no longer exist, forget about this trigger
        {CBModules} ->
            _ = [
                 begin
                     case state_get(trigger_lock, CBModule, State) of
                         free ->
                             log:log(debug, "[ Gossip ] Module ~w got triggered", [CBModule]),
                             log:log(?SHOW, "[ Gossip ] Cycle: ~w, Round: ~w",
                                     [state_get(cycles, CBModule, State), state_get(round, CBModule, State)]),

                             %% set cycle status to active
                             state_set(trigger_lock, locked, CBModule, State),

                             %% reset exch_data
                             state_set(exch_data, {undefined, undefined}, CBModule, State),

                             %% request node (by the cb module or the bh module)
                             case cb_call(select_node, [], Msg, CBModule, State) of
                                 true -> ok;
                                 false -> request_random_node(CBModule)
                             end,

                             %% request data
                             cb_call(select_data, [], Msg, CBModule, State);
                         locked -> do_nothing % ignore trigger when within prepare-request phase
                     end
                 end || CBModule <- CBModules
                ],

            %% trigger next
            msg_delay:send_trigger(TriggerInterval, {gossip_trigger, TriggerInterval}),
            state_set({trigger_group, TriggerInterval}, {CBModules}, State)
    end,
    State;


%% received through the rm on key range changes
on_active({update_range, NewRange}=FullMsg, State) ->
    state_set(range, NewRange, State),
    Msg = case is_leader(NewRange) of
        true -> {is_leader, NewRange};
        false -> {no_leader, NewRange}
    end,
    Fun = fun (CBModule) -> cb_call(notify_change, [leader, Msg], FullMsg, CBModule, State) end,
    CBModules = state_get(cb_modules, State),
    lists:foreach(Fun, CBModules),
    State;


%% request for debug info
on_active({web_debug_info, Requestor}=Msg, State) ->
    CBModules = lists:reverse(state_get(cb_modules, State)),
    Fun = fun (CBModule, Acc) -> Acc ++ [{"",""}] ++
            cb_call(web_debug_info, [], Msg, CBModule, State) end,
    KeyValueList = [{"",""}] ++ web_debug_info(State) ++ lists:foldl(Fun, [], CBModules),
    comm:send_local(Requestor, {web_debug_info_reply, KeyValueList}),
    State;


%% received from shepherd, from on_inactive or from rejected messages
on_active({send_error, _Pid, Msg, Reason}=ErrorMsg, State) ->
    % unpack msg if necessary
    MsgUnpacked = case Msg of
        % msg from shepherd
        {_, ?MODULE, OriginalMsg} -> OriginalMsg;
        % other send_error msgs, e.g. from on_inactive
        _Msg -> _Msg
    end,
    CBStatus = state_get(cb_status, element(2, MsgUnpacked), State),
    case MsgUnpacked of
        _ when CBStatus =:= tombstone ->
            log:log(warn(), "[ Gossip ] Got ~w msg for tombstoned module ~w. Reason: ~w. Original Msg: ~w",
                [element(1, ErrorMsg), element(2, MsgUnpacked), Reason, element(1, Msg)]);
        {p2p_exch, CBModule, _SourcePid, PData, Round} ->
            log:log(warn(), "[ Gossip ] p2p_exch failed because of ~w", [Reason]),
            _ = cb_call(notify_change, [exch_failure, {p2p_exch, PData, Round}], ErrorMsg, CBModule, State);
        {p2p_exch_reply, CBModule, QData, Round} ->
            log:log(warn(), "[ Gossip ] p2p_exch_reply failed because of ~w", [Reason]),
            _ = cb_call(notify_change, [exch_failure, {p2p_exch_reply, QData, Round}], ErrorMsg, CBModule, State);
        _ ->
            log:log(?SHOW, "[ Gossip ] Failed to deliever the Msg ~w because ~w", [Msg, Reason])
    end,
    State;


%% unpack bulkowner msg
on_active({bulkowner, deliver, _Id, _Range, Msg, _Parents}, State) ->
    comm:send_local(self(), Msg),
    State;


%% received through remove_all_tombstones()/bulkowner
on_active({remove_all_tombstones}, State) ->
    TombstoneKeys = get_tombstones(State),
    lists:foreach(fun (Key) -> ?PDB:delete(Key, State) end, TombstoneKeys),
    State;


%% received through deactivate_gossip()/bulkowner
on_active({deactivate_gossip}, State) ->
    log:log(warn, "[ Gossip ] deactivating gossip framwork"),
    rm_loop:unsubscribe(self(), ?MODULE),

    % stop all gossip tasks
    lists:foreach(fun (CBModule) -> handle_msg({stop_gossip_task, CBModule}, State) end,
        state_get(cb_modules, State)),

    % cleanup state
    state_set(status, uninit, State),
    state_set(cb_modules, [], State),
    lists:foreach(fun (Key) -> ?PDB:delete(Key, State) end,
        [msg_queue, range]),

    gen_component:change_handler(State, fun ?MODULE:on_inactive/2);


%% Only messages for callback modules are expected to reach this on_active clause.
%% they have the form:
%%   {MsgTag, CBModule, ...}
%%   element(1, Msg) = MsgTag
%%   element(2, Msg) = CBModule
on_active(Msg, State) ->
    try state_get(cb_status, element(2, Msg), State) of
        tombstone ->
            log:log(warn(), "[ Gossip ] Got ~w msg for tombstoned module ~w",
                [element(1, Msg), element(2, Msg)]);
        unstarted ->
            log:log(?SHOW, "[ Gossip ] Got ~w msg in cbstatus 'unstarted' for ~w",
                [element(1, Msg), element(2, Msg)]),
            msg_queue_add(Msg, State);
        started ->
            handle_msg(Msg, State)
    catch
        _:_ -> log:log(warn(), "[ Gossip ] Unknown msg: ~w", [Msg])
    end,
    State.


%% This message is received as a response to a get_subset message to the
%% cyclon process and should contain a list of random nodes.
-spec handle_msg(Msg::cb_message(), State::state()) -> state().
% re-request node if node list is empty
handle_msg({selected_peer, CBModule, _Msg={cy_cache, []}}, State) ->
    Delay = cb_call(trigger_interval, CBModule),
    request_random_node_delayed(Delay, CBModule),
    State;


handle_msg({selected_peer, CBModule, _Msg={cy_cache, Nodes}}, State) ->
    %% io:format("gossip: got random node from Cyclon: ~p~n",[node:pidX(Node)]),
    {_Node, PData} = state_get(exch_data, CBModule, State),
    case PData of
        undefined -> state_set(exch_data, {Nodes, undefined}, CBModule, State);
        _ -> start_p2p_exchange(Nodes, PData, CBModule, State)
    end,
    State;


%% This message is a reply from a callback module to CBModule:select_data()
handle_msg({selected_data, CBModule, PData}, State) ->
    % check if a peer has been received already
    {Peer, _PData} = state_get(exch_data, CBModule, State),
    case Peer of
        undefined -> state_set(exch_data, {undefined, PData}, CBModule, State);
        _ -> start_p2p_exchange(Peer, PData, CBModule, State)
    end,
    State;


%% This message is a request from another peer (i.e. another gossip module) to
%% exchange data, usually results in CBModule:select_reply_data()
handle_msg({p2p_exch, CBModule, SourcePid, PData, OtherRound}=Msg, State) ->
    log:log(debug, "[ Gossip ] p2p_exch msg received from ~w. PData: ~w",[SourcePid, PData]),
    state_set({reply_peer, Ref=uid:get_pids_uid()}, SourcePid, State),
    case check_round(OtherRound, CBModule, State) of
        ok ->
            select_reply_data(PData, Ref, current_round, OtherRound, Msg, CBModule, State);
        start_new_round -> % self is leader
            log:log(?SHOW, "[ Gossip ] Starting a new round in p2p_exch"),
            _ = cb_call(notify_change, [new_round, state_get(round, CBModule, State)], Msg, CBModule, State),
            select_reply_data(PData, Ref, old_round, OtherRound, Msg, CBModule, State),
            comm:send(SourcePid, {new_round, CBModule, state_get(round, CBModule, State)});
        enter_new_round ->
            log:log(?SHOW, "[ Gossip ] Entering a new round in p2p_exch"),
            _ = cb_call(notify_change, [new_round, state_get(round, CBModule, State)], Msg, CBModule, State),
            select_reply_data(PData, Ref, current_round, OtherRound, Msg, CBModule, State);
        propagate_new_round -> % i.e. MyRound > OtherRound
            log:log(debug, "[ Gossip ] propagate round in p2p_exch"),
            select_reply_data(PData, Ref, old_round, OtherRound, Msg, CBModule, State),
            comm:send(SourcePid, {new_round, CBModule, state_get(round, CBModule, State)})
    end,
    State;


%% This message is a reply from a callback module to CBModule:select_reply_data()
handle_msg({selected_reply_data, CBModule, QData, Ref, Round}, State)->
    Peer = state_take({reply_peer, Ref}, State),
    log:log(debug, "[ Gossip ] selected_reply_data. CBModule: ~w, QData ~w, Peer: ~w",
        [CBModule, QData, Peer]),
    comm:send(Peer, {p2p_exch_reply, CBModule, comm:this(), QData, Round}, [{shepherd, self()}]),
    State;


%% This message is a reply from another peer (i.e. another gossip module) to
%% a p2p_exch request, usually results in CBModule:integrate_data()
handle_msg({p2p_exch_reply, CBModule, SourcePid, QData, OtherRound}=Msg, State) ->
    log:log(debug, "[ Gossip ] p2p_exch_reply, CBModule: ~w, QData ~w", [CBModule, QData]),
    _ = case check_round(OtherRound, CBModule, State) of
        ok ->
            _ = cb_call(integrate_data, [QData, current_round, OtherRound], Msg, CBModule, State);
        start_new_round -> % self is leader
            log:log(?SHOW, "[ Gossip ] Starting a new round p2p_exch_reply"),
            _ = cb_call(notify_change, [new_round, state_get(round, CBModule, State)], Msg, CBModule, State),
            _ = cb_call(integrate_data, [QData, old_round, OtherRound], Msg, CBModule, State),
            comm:send(SourcePid, {new_round, CBModule, state_get(round, CBModule, State)});
        enter_new_round ->
            log:log(?SHOW, "[ Gossip ] Entering a new round p2p_exch_reply"),
            _ = cb_call(notify_change, [new_round, state_get(round, CBModule, State)], Msg, CBModule, State),
            _ = cb_call(integrate_data, [QData, current_round, OtherRound], Msg, CBModule, State);
        propagate_new_round -> % i.e. MyRound > OtherRound
            log:log(debug, "[ Gossip ] propagate round in p2p_exch_reply"),
            comm:send(SourcePid, {new_round, CBModule, state_get(round, CBModule, State)}),
            _ = cb_call(integrate_data, [QData, old_round, OtherRound], Msg, CBModule, State)
    end,
    State;


%% This message is a reply from a callback module to CBModule:integrate_data()
%% Markes the end of a cycle
handle_msg({integrated_data, CBModule, current_round}, State) ->
    state_update(cycles, fun (X) -> X+1 end, CBModule, State),
    State;


% finishing an old round should not affect cycle counter of current round
handle_msg({integrated_data, _CBModule, old_round}, State) ->
    State;


%% pass messages for callback modules to the respective callback module
%% messages to callback modules need to have the form {cb_reply, CBModule, Msg}.
%% Use envelopes if necessary.
handle_msg({cb_reply, CBModule, Msg}=FullMsg, State) ->
    _ = cb_call(handle_msg, [Msg], FullMsg, CBModule, State),
    State;

% round propagation message
handle_msg({new_round, CBModule, NewRound}=Msg, State) ->
    MyRound = state_get(round, CBModule, State),
    if
        MyRound < NewRound ->
            log:log(?SHOW, "[ Gossip ] Entering new round via round propagation message"),
            _ = cb_call(notify_change, [new_round, NewRound], Msg, CBModule, State),
            state_set(round, NewRound, CBModule, State),
            state_set(cycles, 0, CBModule, State);
        MyRound =:= NewRound -> % i.e. the round propagation msg was already received
            log:log(?SHOW, "[ Gossip ] Received propagation msg for round i'm already in"),
            do_nothing;
        MyRound > NewRound ->
            log:log(?SHOW, "[ Gossip ] MyRound > OtherRound")
    end,
    State;


%% passes a get_values_best request to the callback module
%% received from webhelpers and lb_psv_gossip
handle_msg({get_values_best, CBModule, SourcePid}=Msg, State) ->
    BestValues = cb_call(get_values_best, [], Msg, CBModule, State),
    comm:send_local(SourcePid, {gossip_get_values_best_response, BestValues}),
    State;


%% passes a get_values_all (all: current, previous and best values) request to
%% the callback module
handle_msg({get_values_all, CBModule, SourcePid}=Msg, State) ->
    {Prev, Current, Best} = cb_call(get_values_all, [], Msg, CBModule, State),
    comm:send_local(SourcePid,
        {gossip_get_values_all_response, Prev, Current, Best}),
    State;


%% Received through stop_gossip_task/bulkowner
%% Stops gossip tasks and cleans state of all garbage
%% sets tombstone to handle possible subsequent request for already stopped tasks
handle_msg({stop_gossip_task, CBModule}=Msg, State) ->
    log:log(?SHOW, "[ Gossip ] Stopping ~w", [CBModule]),
    % shutdown callback module
    _ = cb_call(shutdown, [], Msg, CBModule, State),

    % delete callback module dependet entries from state
    Fun = fun (Key) -> ?PDB:delete({Key, CBModule}, State) end,
    lists:foreach(Fun, [cb_state, cb_status, cycles, trigger_lock, exch_data, round]),

    % remove from list of modules
    Fun1 = fun (ListOfModules) -> lists:delete(CBModule, ListOfModules) end,
    state_update(cb_modules, Fun1, State),

    % remove from trigger group
    Interval = cb_call(trigger_interval, CBModule) div 1000,
    {CBModules} = state_get({trigger_group, Interval}, State),
    NewCBModules = lists:delete(CBModule, CBModules),
    case NewCBModules of
        [] ->
            ?PDB:delete({trigger_group, Interval}, State);
        _ ->
            state_set({trigger_group, Interval}, {NewCBModules}, State)
    end,

    % set tombstone
    state_set(cb_status, tombstone, CBModule, State),
    State.


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Msg Exchange with Peer
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

% called by either on({selected_data,...}) or on({selected_peer, ...}),
% depending on which finished first
-spec start_p2p_exchange(Peers::[node:node_type(),...], PData::gossip_beh:exch_data(),
    CBModule::cb_module_name(), State::state()) -> ok.
start_p2p_exchange(Peers, PData, CBModule, State)  ->
    _ = [ begin
        case node:is_me(Peer) of
            false ->
                %% io:format("starting p2p exchange. Peer: ~w, Ref: ~w~n",[Peer, Ref]),
                ?SEND_TO_GROUP_MEMBER(
                        node:pidX(Peer), gossip,
                        {p2p_exch, CBModule, comm:this(), PData, state_get(round, CBModule, State)}),
                state_set(trigger_lock, free, CBModule, State);
            true  ->
                %% todo does this really happen??? cyclon should not have itself in the cache
                log:log(?SHOW, "[ Gossip ] Node was ME, requesting new node"),
                request_random_node(CBModule),
                {Peer, Data} = state_get(exch_data, CBModule, State),
                state_set(exch_data, {undefined, Data}, CBModule, State)
        end
        end || Peer <- Peers],
    ok.


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Interacting with the Callback Modules
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% called when activating gossip module
-spec init_gossip_tasks(State::state()) -> ok.
init_gossip_tasks(State) ->
    Fun = fun (CBModule) ->
            state_set(cb_status, unstarted, CBModule, State),
            comm:send_local(self(), {start_gossip_task, CBModule, []})
          end,
    lists:foreach(Fun, ?CBMODULES).


%% initialises a gossip task / callback mdoule
%% called on activation of gossip module or on start_gossip_task message
-spec init_gossip_task(CBModule::cb_module_name(), Args::list(), State::state()) -> ok.
init_gossip_task(CBModule, Args, State) ->

    % initialize CBModule
    {ok, CBState} = cb_call(init, [CBModule|Args], CBModule),

    % add state ob CBModule to state
    state_set(cb_state, CBState, CBModule, State),

    % set cb_status to init
    state_set(cb_status, started, CBModule, State),

    % notify cb module about leader state
    MyRange = state_get(range, State),
    LeaderMsg = case is_leader(MyRange) of
        true -> {is_leader, MyRange};
        false -> {no_leader, MyRange}
    end,

    % TODO no_msg is no solution
    _ = cb_call(notify_change, [leader, LeaderMsg], no_msg, CBModule, State),

    % configure and add trigger
    TriggerInterval = cb_call(trigger_interval, CBModule) div 1000,
    {TriggerGroup} =
    case state_get_raw({trigger_group, TriggerInterval}, State) of
        undefined ->
            % create and init new trigger group
            msg_delay:send_trigger(?FIRST_TRIGGER_DELAY,  {gossip_trigger, TriggerInterval}),
            {[CBModule]};
        {OldTriggerGroup} ->
            % add CBModule to existing trigger group
            {[CBModule|OldTriggerGroup]}
    end,
    state_set({trigger_group, TriggerInterval}, {TriggerGroup}, State),

    % add CBModule to list of cbmodules
    CBModules = state_get(cb_modules, State),
    state_set(cb_modules, [CBModule|CBModules], State),

    % initialize exch_data table with empty entry
    state_set(exch_data, {undefined, undefined}, CBModule, State),

    % set cycles to 0
    state_set(cycles, 0, CBModule, State),

    % set rounds to 0
    state_set(round, 0, CBModule, State),

    % set cycle status to inactive (gets activated by trigger)
    state_set(trigger_lock, free, CBModule, State),

    ok.


-spec cb_call(FunName, CBModule) -> non_neg_integer() | pos_integer() when
    is_subtype(FunName, fanout | min_cycles_per_round | max_cycles_per_round | trigger_interval),
    is_subtype(CBModule, cb_module_name()).
cb_call(FunName, CBModule) ->
    cb_call(FunName, [], CBModule).

-spec cb_call(FunName, Args, CBModule) -> Return when
    is_subtype(FunName, init | fanout | min_cycles_per_round | max_cycles_per_round | trigger_interval),
    is_subtype(Args, list()),
    is_subtype(CBModule, cb_module_name()),
    is_subtype(Return, non_neg_integer() | pos_integer() | {ok, any()}).
cb_call(FunName, Args, CBModule) ->
    {CBModuleName, _Id} = CBModule,
    apply(CBModuleName, FunName, Args).


%% call to a callback module
%% wraps some common functionaly of all calls to callback modules, like inserting
%% the respective callback module's state and unpacking the ModuleName/InstanceId tuple
-spec cb_call(FunName, Arguments, Msg, CBModule, State) -> Return when
    is_subtype(FunName, cb_fun_name()),
    is_subtype(Arguments, list()),
    is_subtype(Msg, message()),
    is_subtype(CBModule, cb_module_name()),
    is_subtype(State, state()),
    is_subtype(Return, ok | discard_msg
        | send_back | boolean() | {any(), any(), any()} | list({list(), list()})).
cb_call(FunName, Args, Msg, CBModule, State) ->
    {ModuleName, _InstanceId} = CBModule,
    CBState = state_get(cb_state, CBModule, State),
    Args1 = Args ++ [CBState],
    ReturnTuple = apply(ModuleName, FunName, Args1),
    case ReturnTuple of
        {ok, ReturnedCBState} ->
            log:log(debug, "[ Gossip ] cb_call: ReturnTuple: ~w, ReturendCBState ~w", [ReturnTuple, ReturnedCBState]),
            state_set(cb_state, ReturnedCBState, CBModule, State), ok;
        {retry, ReturnedCBState} ->
            msg_queue_add(Msg, State),
            state_set(cb_state, ReturnedCBState, CBModule, State),
            discard_msg;
        {discard_msg, ReturnedCBState} ->
            state_set(cb_state, ReturnedCBState, CBModule, State),
            discard_msg;
        {send_back, ReturnedCBState} ->
            case Msg of
                {p2p_exch,_,SourcePid,_,_} ->
                    comm:send(SourcePid, {send_error, comm:this(), Msg, message_rejected});
                {p2p_exch_reply,_,SourcePid,_,_} ->
                    comm:send(SourcePid, {send_error, comm:this(), Msg, message_rejected});
                _Other ->
                    log:log(error, "send_back on non backsendable msg")
            end,
            state_set(cb_state, ReturnedCBState, CBModule, State),
            send_back;
        {ReturnValue, ReturnedCBState} ->
            log:log(debug, "[ Gossip ] cb_call: ReturnTuple: ~w, ReturnValue: ~w ReturendCBState: ~w",
                [ReturnTuple, ReturnValue, ReturnedCBState]),
            state_set(cb_state, ReturnedCBState, CBModule, State),
            ReturnValue
    end.


%% special function for calls to CBModule:select_reply_data
%% removes the reply_peer from the state of the gossip module
%% This is necessary if the callback module will not send an selected_reply_data
%% message (because the message is dscarded or sent back directly)
-spec select_reply_data(PData::gossip_beh:exch_data(), Ref::pos_integer(),
    RoundStatus::gossip_beh:round_status(), Round::non_neg_integer(),
    Msg::message(), CBModule::cb_module_name(), State::state()) -> ok.
select_reply_data(PData, Ref, RoundStatus, Round, Msg, CBModule, State) ->
    case cb_call(select_reply_data, [PData, Ref, RoundStatus, Round], Msg, CBModule, State) of
        ok -> ok;
        discard_msg ->
            state_take({reply_peer, Ref}, State), ok;
        send_back ->
            state_take({reply_peer, Ref}, State), ok
    end.


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Requesting Peers
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% @doc Sends the local node's cyclon process an enveloped request for a random node.
%%      on_active({selected_peer, CBModule, {cy_cache, Cache}}, State) will handle the response
-spec request_random_node(CBModule::cb_module_name()) -> ok.
request_random_node(CBModule) ->
    CyclonPid = pid_groups:get_my(cyclon),
    EnvPid = comm:reply_as(self(), 3, {selected_peer, CBModule, '_'}),
    Fanout = cb_call(fanout, CBModule),
    comm:send_local(CyclonPid, {get_subset_rand, Fanout, EnvPid}).


%% Used for rerequesting peers from cyclon when cyclon returned an empty list,
%% which is usually the case during startup.
%% The delay prohibits bombarding the cyclon process with requests.
-spec request_random_node_delayed(Delay::non_neg_integer(), CBModule::cb_module_name()) ->
    reference().
request_random_node_delayed(Delay, CBModule) ->
    CyclonPid = pid_groups:get_my(cyclon),
    EnvPid = comm:reply_as(self(), 3, {selected_peer, CBModule, '_'}),
    Fanout = cb_call(fanout, CBModule),
    comm:send_local_after(Delay, CyclonPid, {get_subset_rand, Fanout, EnvPid}).


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Round Handling
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% called at every p2p_exch and p2p_exch_reply message
-spec check_round(OtherRound::non_neg_integer(), CBModule::cb_module_name(), State::state())
    -> ok | start_new_round | enter_new_round | propagate_new_round.
check_round(OtherRound, CBModule, State) ->
    MyRound = state_get(round, CBModule, State),
    Leader = is_leader(state_get(range, State)),
    case MyRound =:= OtherRound of
        true when Leader ->
            case is_end_of_round(CBModule, State) of
                true ->
                    state_update(round, fun (X) -> X+1 end, CBModule, State),
                    state_set(cycles, 0, CBModule, State),
                    start_new_round;
                false -> ok
            end;
        true -> ok;
        false when MyRound < OtherRound ->
            state_set(round, OtherRound, CBModule, State),
            state_set(cycles, 0, CBModule, State),
            enter_new_round;
        false when MyRound > OtherRound ->
            propagate_new_round
    end.


%% checks the convergence of the current round (only called at leader)
-spec is_end_of_round(CBModule::cb_module_name(), State::state()) -> boolean().
is_end_of_round(CBModule, State) ->
    Cycles = state_get(cycles, CBModule, State),
    log:log(debug, "[ Gossip ] check_end_of_round. Cycles: ~w", [Cycles]),
    Cycles >= cb_call(min_cycles_per_round, CBModule) andalso
    (   ( Cycles >= cb_call(max_cycles_per_round, CBModule)) orelse
        ( cb_call(round_has_converged, [], no_msg, CBModule, State) ) ).


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Range/Leader Handling
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% @doc Checks whether the node is the current leader.
-spec is_leader(MyRange::intervals:interval()) -> boolean().
is_leader(MyRange) ->
    intervals:in(?RT:hash_key("0"), MyRange).


%% @doc Checks whether the node's range has changed, i.e. either the node
%%      itself or its pred changed.
-spec rm_my_range_changed(OldNeighbors::nodelist:neighborhood(),
                          NewNeighbors::nodelist:neighborhood(),
                          IsSlide::rm_loop:reason()) -> boolean().
rm_my_range_changed(OldNeighbors, NewNeighbors, _IsSlide) ->
    nodelist:node(OldNeighbors) =/= nodelist:node(NewNeighbors) orelse
        nodelist:pred(OldNeighbors) =/= nodelist:pred(NewNeighbors).


%% @doc Notifies the node's gossip process of a changed range.
%%      Used to subscribe to the ring maintenance.
-spec rm_send_new_range(Subscriber::pid(), Tag::?MODULE,
                        OldNeighbors::nodelist:neighborhood(),
                        NewNeighbors::nodelist:neighborhood(),
                        Reason::rm_loop:reason()) -> ok.
rm_send_new_range(Pid, ?MODULE, _OldNeighbors, NewNeighbors, _Reason) ->
    NewRange = nodelist:node_range(NewNeighbors),
    comm:send_local(Pid, {update_range, NewRange}).


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% State: Getters and Setters
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% @doc Gets the given key from the given state.
%%      Allowed keys:
%%      <ul>
%%        <li>`cb_modules', a list of registered callback modules ,</li>
%%        <li>`msg_queue', the message queue of the behaviour module, </li>
%%        <li>`range', the key range of the node, </li>
%%        <li>`{reply_peer, Ref}', the peer to send the p2p_exch_reply to, </li>
%%        <li>`{trigger_group, TriggerInterval}', trigger group, </li>
%%      </ul>
-spec state_get(Key::state_key(), State::state()) -> any().
state_get(Key, State) ->
    case ?PDB:get(Key, State) of
        {Key, Value} -> Value;
        undefined ->
            log:log(error(), "[ gossip ] Lookup of ~w in ~w failed", [Key, State]),
            erlang:error(lookup_failed, [Key, State])
    end.

%% returns undefined on non-existing keys
-spec state_get_raw(Key::state_key(), State::state()) -> any().
state_get_raw(Key, State) ->
    case ?PDB:get(Key, State) of
        {Key, Value} -> Value;
        undefined -> undefined
    end.


%% returns a removes an entry
-spec state_take(Key::state_key(), State::state()) -> any().
state_take(Key, State) ->
    case ?PDB:take(Key, State) of
        {Key, Value} -> Value;
        undefined ->
            log:log(error, "[ gossip ] Take of ~w in ~w failed", [Key, State]),
            erlang:error(lookup_failed, [Key, State])
    end.

%% sets and entry
-spec state_set(Key::state_key(), Value::any(), State::state()) -> ok.
state_set(Key, Value, State) ->
    ?PDB:set({Key, Value}, State).

%% updates an entry with the given update function
-spec state_update(Key::state_key(), UpdateFun::fun(), State::state()) -> ok.
state_update(Key, Fun, State) ->
    NewValue = apply(Fun, [state_get(Key, State)]),
    state_set(Key, NewValue, State).

%%---------------- Callback Module Specific State ------------------%%

%% @doc Gets the given key belonging to the given callback module from the given state.
%%      Allowed keys:
%%      <ul>
%%        <li>`cb_state', the state of the given callback module </li>
%%        <li>`cb_status', indicates, if `init()' was called on callback module
%%                  (allowed values: unstarted, started) </li>
%%        <li>`exch_data', a tuple of the data to exchange and the peer to
%%                  exchange the data with. Can be one of the following: </li>
%%          <ul>
%%            <li>`{undefined, undefined}'</li>
%%            <li>`{undefined, Peer::comm:mypid()}'</li>
%%            <li>`{ExchData::any(), undefined}'</li>
%%            <li>`{ExchData::any(), Peer::comm:mypid()}'</li>
%%          </ul>
%%        <li>`round', the round of the given callback </li>
%%        <li>`trigger_lock', locks triggering while within prepare-request phase
%%              (allowed values: free, locked) </li>
%%        <li>`cycles', cycle counter, </li>
%%      </ul>
-spec state_get(Key::state_key_cb(), CBModule::cb_module_name(), State::state()) -> any().
state_get(Key, CBModule, State) ->
    state_get({Key, CBModule}, State).


%% state_get_raw(Key, CBModule, State) ->
%%     state_get_raw({Key, CBModule}, State).
%%

%% @doc Sets the given value for the given key in the given state.
%%      Allowed keys see state_get/3
-spec state_set(Key::state_key_cb(), Value::any(), CBModule::cb_module_name(), State::state()) -> ok.
state_set(Key, Value, CBModule, State) ->
    state_set({Key, CBModule}, Value, State).

%% updates the state with the given function
-spec state_update(Key::state_key_cb(), UpdateFun::fun(), CBModule::cb_module_name(), State::state()) -> ok.
state_update(Key, Fun, CBModule, State) ->
    Value = apply(Fun, [state_get(Key, CBModule, State)]),
    state_set(Key, Value, CBModule, State).


%%------------------------- Message Queue --------------------------%%

%% add to message queue and create message queue if necessary
-spec msg_queue_add(Msg::message(), State::state()) -> ok.
msg_queue_add(Msg, State) ->
    MsgQueue = case state_get_raw(msg_queue, State) of
        undefined -> msg_queue:new();
        CurrentMsgQueue -> CurrentMsgQueue
    end,
    NewMsgQueue = msg_queue:add(MsgQueue, Msg),
    state_set(msg_queue, NewMsgQueue, State).


%% send the messages from the current message queue and create a new message queue
-spec msg_queue_send(State::state()) -> ok.
msg_queue_send(State) ->
    NewMsgQueue = case state_get_raw(msg_queue, State) of
        undefined -> msg_queue:new();
        MsgQueue ->
            msg_queue:send(MsgQueue),
            msg_queue:new()
    end,
    state_set(msg_queue, NewMsgQueue, State).


%% gets als the tombstones from the state of the gossip module
-spec get_tombstones(State::state()) -> list({cb_status, cb_module_name()}).
get_tombstones(State) ->
    StateList = ?PDB:tab2list(State),
    Fun = fun ({{cb_status, CBModule}, Status}, Acc) ->
            if Status =:= tombstone -> [{cb_status, CBModule}|Acc];
               Status =/= tombstone -> Acc
            end;
        (_Entry, Acc) -> Acc end,
    lists:foldl(Fun, [], StateList).


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Misc
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% provide some debug information for the gossip moudle (to be added to the
%% information of a the callback modules)
-spec web_debug_info(State::state()) -> [{_,_}, ...].
web_debug_info(State) ->
    CBModules = state_get(cb_modules, State),
    Tombstones = lists:map(fun ({cb_status, CBModule}) -> CBModule end, get_tombstones(State)),
    _KeyValueList =
        [{"behaviour module",   ""},
         {"msg_queue_len",      length(state_get(msg_queue, State))},
         {"status",             state_get(status, State)},
         {"registered modules", to_string(CBModules)},
         {"tombstones",         to_string(Tombstones)}
     ].


%% contains function on list, returns true if list contains Element
-spec contains(Element::any(), List::list()) -> boolean().
contains(_Element, []) -> false;

contains(Element, [H|List]) ->
    if H =:= Element -> true;
       H =/= Element -> contains(Element, List)
    end.


%% Returns a list as string
-spec to_string(list()) -> string().
to_string(List) when is_list(List) ->
    lists:flatten(io_lib:format("~w", [List])).



%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% For Testing
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% @doc Value creater for type_check_SUITE
-spec tester_create_state(Status, Range, Interval,
    CBState, CBStatus, ExchData, Round, TriggerLock, Cycles) -> state()
    when    is_subtype(Status, init | uninit),
            is_subtype(Range, intervals:interval()),
            is_subtype(Interval, pos_integer()),
            is_subtype(CBState, any()),
            is_subtype(CBStatus, unstarted | started | tombstone),
            is_subtype(ExchData, any()),
            is_subtype(Round, non_neg_integer()),
            is_subtype(TriggerLock, free | locked),
            is_subtype(Cycles, non_neg_integer()).
tester_create_state(Status, Range, Interval, CBState, CBStatus,
        ExchData, Round, TriggerLock, Cycles) ->
    State = ?PDB:new(state, ?PDB_OPTIONS),
    state_set(status, Status, State),
    state_set(cb_modules, ?CBMODULES, State),
    state_set(msg_queue, msg_queue:new(), State),
    state_set(range, Range, State),
    state_set({reply_peer, uid:get_pids_uid()}, comm:this(), State),
    state_set({trigger_group, Interval}, {?CBMODULES}, State),
    Fun = fun (CBModule) ->
            state_set(cb_state, CBState, CBModule, State),
            state_set(cb_status, CBStatus, CBModule, State),
            state_set(exch_data, {ExchData, comm:this()}, CBModule, State),
            state_set(round, Round, CBModule, State),
            state_set(trigger_lock, TriggerLock, CBModule, State),
            state_set(cycles, Cycles, CBModule, State)
    end,
    lists:foreach(Fun, ?CBMODULES),
    State.

%% @doc Value creater for type_check_SUITE.
-spec tester_gossip_beh_modules(1) -> gossip:cb_module().
tester_gossip_beh_modules(1) ->
    gossip_load.

%%% @doc Type checker for type_check SUITE
-spec is_state(State::state()) -> boolean().
is_state(State) ->
    try
        StateAsList = ?PDB:tab2list(State),
        SimpleKeys = [cb_modules, msg_queue, range],
        Fun1 = fun (Key, AccIn) ->
                case lists:keyfind(Key, 1, StateAsList) of
                    false -> AccIn andalso false;
                    _ -> AccIn andalso true
                end
        end,
        HasKeys1 = lists:foldl(Fun1, true, SimpleKeys),
        % reply_peer exlcuded
        TupleKeys = [trigger_group, cb_state, cycles, trigger_lock, exch_data, round],
        Fun2 = fun (Key, AccIn) -> AccIn andalso tuplekeyfind(Key, StateAsList) =/= false end,
        HasKeys2 = lists:foldl(Fun2, true, TupleKeys),
        HasKeys1 andalso HasKeys2
    catch
        % if ets table does not exist
        error:badarg -> false
    end.

%% find {{keyword, CMbodule}, {Value}} tuples by only the keyword
-spec tuplekeyfind(atom(), list()) -> {{atom(), any()}, any()} | false.
tuplekeyfind(_Key, []) -> false;

tuplekeyfind(Key, [H|List]) ->
    case H of
        Tuple = {{TupleKey, _}, _} ->
            if  Key =:= TupleKey -> Tuple;
                Key =/= TupleKey -> tuplekeyfind(Key, List)
            end;
        _ -> tuplekeyfind(Key, List)
    end.

-compile({nowarn_unused_function, {init_gossip_task_feeder, 3}}).
-spec init_gossip_task_feeder(cb_module_name(), [1..50], state()) -> {cb_module_name(), list(), state()}.
init_gossip_task_feeder(CBModule, Args, State) ->
    Args1 = if length(Args)>1 -> [hd(Args)];
               true -> Args
            end,
    {CBModule, Args1, State}.

-compile({nowarn_unused_function, {request_random_node_delayed_feeder, 2}}).
-spec request_random_node_delayed_feeder(Delay::0..1000, CBModule::cb_module_name()) ->
    {non_neg_integer(), cb_module_name()}.
request_random_node_delayed_feeder(Delay, CBModule) ->
    {Delay, CBModule}.

-compile({nowarn_unused_function, {state_get_feeder, 2}}).
-spec state_get_feeder(Key::state_key(), State::state()) -> {state_key(), state()}.
state_get_feeder(Key, State) ->
    state_feeder_helper(Key, State).

-compile({nowarn_unused_function, {state_take_feeder, 2}}).
-spec state_take_feeder(Key::state_key(), State::state()) -> {state_key(), state()}.
state_take_feeder(Key, State) ->
    state_feeder_helper(Key, State).

-compile({nowarn_unused_function, {state_feeder_helper, 2}}).
-spec state_feeder_helper(state_key(), state()) -> {state_key(), state()}.
state_feeder_helper(Key, State) ->
    case Key of
        {reply_peer, _} ->
            {KeyTuple, _Value} = tuplekeyfind(reply_peer, ?PDB:tab2list(State)),
            {KeyTuple, State};
        {trigger_group, _} ->
            {KeyTuple, _Value} = tuplekeyfind(reply_peer, ?PDB:tab2list(State)),
            {KeyTuple, State};
        _ -> {Key, State}
    end.

%% hack to be able to suppress warnings when testing via config:write()
-spec warn() -> log:log_level().
warn() ->
    case config:read(gossip_log_level_warn) of
        failed -> warn;
        Level -> Level
    end.

%% hack to be able to suppress warnings when testing via config:write()
-spec error() -> log:log_level().
error() ->
    case config:read(gossip_log_level_error) of
        failed -> warn;
        Level -> Level
    end.

%% @doc Check the config of the gossip module. <br/>
%%      Calls the check_config functions of all callback modules.
-spec check_config() -> boolean().
check_config() ->
    lists:foldl(fun({Module, _Args}, Acc) -> Acc andalso Module:check_config() end, true, ?CBMODULES).
