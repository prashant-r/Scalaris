% @copyright 2011, 2012 Zuse Institute Berlin

%   Licensed under the Apache License, Version 2.0 (the "License");
%   you may not use this file except in compliance with the License.
%   You may obtain a copy of the License at
%
%       http://www.apache.org/licenses/LICENSE-2.0
%
%   Unless required by applicable request_resolvelaw or agreed to in writing, software
%   distributed under the License is distributed on an "AS IS" BASIS,
%   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%   See the License for the specific language governing permissions and
%   limitations under the License.

%% @author Maik Lange <malange@informatik.hu-berlin.de>
%% @doc    replica update resolution module
%%         Updates local and/or remote Key-Value-Pairs (kv-pair)
%%         Sync-Modes:
%%           1) key_upd: updates local kv-pairs with received kv-list, if received kv is newer
%%           2) key_upd_dest: creates kv-list out of a given key-list and sends it to dest
%%         Options:
%%           1) Feedback: sends data ids to Node (A) which are outdated at (A)
%%           2) Send_Stats: sends resolution stats to given pid
%%         Usage:
%%           rrepair process provides API for resolve requests
%% @end
%% @version $Id$

-module(rr_resolve).

-behaviour(gen_component).

-include("record_helpers.hrl").
-include("scalaris.hrl").

-export([init/1, on/2, start/3]).
-export([print_resolve_stats/1]).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% debug
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%-define(TRACE(X,Y), io:format("~w [~p] " ++ X ++ "~n", [?MODULE, self()] ++ Y)).
-define(TRACE(X,Y), ok).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% type definitions
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
-ifdef(with_export_type_support).
-export_type([operation/0, options/0]).
-export_type([stats/0]).
-endif.

-type option()   :: feedback_response |
                    {feedback, comm:mypid()} | 
                    {send_stats, comm:mypid()}. %send stats to pid after completion
-type options()  :: [option()].
-type feedback() :: {nil | comm:mypid(),        %feedback destination adress
                     ?DB:kvv_list()}.

-record(resolve_stats,
        {
         round            = {0, 0} :: rrepair:round(),
         diff_size        = 0      :: non_neg_integer(),
         regen_count      = 0      :: non_neg_integer(),
         update_count     = 0      :: non_neg_integer(),
         upd_fail_count   = 0      :: non_neg_integer(),
         regen_fail_count = 0      :: non_neg_integer(),
         comment          = []     :: [any()]
         }).
-type stats() :: #resolve_stats{}.

-type operation() ::
    {key_upd, ?DB:kvv_list()} |
    {key_upd_dest, DestPid::comm:mypid(), [?RT:key()]}.

-record(rr_resolve_state,
        {
         ownerLocalPid  = ?required(rr_resolve_state, ownerLocalPid)    :: comm:erl_local_pid(),
         ownerRemotePid = ?required(rr_resolve_state, ownerRemotePid)   :: comm:mypid(),         
         dhtNodePid     = ?required(rr_resolve_state, dhtNodePid)       :: comm:erl_local_pid(),
         operation      = ?required(rr_resolve_state, operation)        :: operation(),
         stats          = #resolve_stats{}                              :: stats(),
         feedback       = {nil, []}                                     :: feedback(),
         feedback_resp  = false                                         :: boolean(),           %true if this is a feedback response
         send_stats     = nil                                           :: nil | comm:mypid() 
         }).
-type state() :: #rr_resolve_state{}.

-type message() ::
    % internal
    {get_state_response, intervals:interval()} |
    {update_key_entry_ack, db_entry:entry(), Exists::boolean(), Done::boolean()} |
    {shutdown, {atom(), stats()}}.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% Message handling
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
-spec on(message(), state()) -> state().

on({get_state_response, MyI}, State = 
       #rr_resolve_state{ operation = {key_upd, KvvList},
                          dhtNodePid = DhtPid,
                          stats = Stats
                          }) ->    
    MyPid = comm:this(),
    ToUpdate = 
        lists:foldl(
          fun({Key, Value, Vers}, Acc) ->
                  UpdKeys = [X || X <- ?RT:get_replica_keys(Key), intervals:in(X, MyI)],
                  lists:foreach(fun(UpdKey) ->
                                        comm:send_local(DhtPid, 
                                                        {update_key_entry, MyPid, UpdKey, Value, Vers})
                                end, UpdKeys),
                  Acc + length(UpdKeys)
          end, 0, KvvList),
    %kill is done by update_key_entry_ack
    ?TRACE("GET INTERVAL - KEY UPD - MYI=~p;KVVListLen=~p ; ToUpdate=~p", [MyI, length(KvvList), ToUpdate]),
    ToUpdate =:= 0 andalso
        comm:send_local(self(), {shutdown, {resolve_ok, Stats}}),
    State#rr_resolve_state{ stats = Stats#resolve_stats{ diff_size = ToUpdate } };

on({get_state_response, MyI}, State =
       #rr_resolve_state{ operation = {key_upd_dest, _, KeyList},
                          dhtNodePid = DhtPid }) ->    
    FilterKeyList = [K || X <- KeyList, 
                          K <- ?RT:get_replica_keys(X), 
                          intervals:in(K, MyI)],
    UpdI = intervals:from_elements(FilterKeyList),
    comm:send_local(DhtPid, {get_entries, self(), 
                             fun(X) -> intervals:in(db_entry:get_key(X), UpdI) end,
                             fun(X) -> {db_entry:get_key(X),
                                        db_entry:get_value(X), 
                                        db_entry:get_version(X)} end}),
    State;

on({get_entries_response, KVVList}, State =
       #rr_resolve_state{ operation = {key_upd_dest, Dest, _},
                          ownerRemotePid = MyNodePid,
                          feedback = {FB, _},
                          stats = Stats }) ->
    ?TRACE("START GET ENTRIES - KEY SYNC", []),
    Options = case FB of
                  nil -> [];
                  _ -> [{feedback, FB}]
              end,
    comm:send(Dest, {request_resolve, Stats#resolve_stats.round, {key_upd, KVVList}, Options}),
    comm:send_local(self(), {shutdown, {resolve_ok, Stats}}),
    State;

on({update_key_entry_ack, Entry, Exists, Done}, State =
       #rr_resolve_state{ operation = {key_upd, _},
                          stats = #resolve_stats{ diff_size = Diff,
                                                  regen_count = RegenOk,
                                                  update_count = UpdOk, 
                                                  upd_fail_count = UpdFail,
                                                  regen_fail_count = RegenFail,
                                                  round = Round
                                                } = Stats,                          
                          feedback = FB = {DoFB, FBItems}
                        }) ->
    NewStats = if
                   Done andalso Exists -> Stats#resolve_stats{ update_count = UpdOk +1 };
                   Done andalso not Exists -> Stats#resolve_stats{ regen_count = RegenOk +1 };
                   not Done and Exists -> Stats#resolve_stats{ upd_fail_count = UpdFail + 1 };
                   not Done and not Exists -> Stats#resolve_stats{ regen_fail_count = RegenFail + 1 }
               end,
    NewFB = if
                not Done andalso Exists andalso DoFB =/= nil -> 
                    {DoFB, [{db_entry:get_key(Entry),
                            db_entry:get_value(Entry),
                            db_entry:get_version(Entry)} | FBItems]};
                true -> FB
            end,
    if
        (Diff -1) =:= (RegenOk + UpdOk + UpdFail + RegenFail) ->
                send_feedback(NewFB, Round),
                comm:send_local(self(), {shutdown, {resolve_ok, NewStats}});
        true -> ok
    end,
    State#rr_resolve_state{ stats = NewStats, feedback = NewFB };

on({shutdown, _}, #rr_resolve_state{ ownerLocalPid = Owner,   
                                     send_stats = SendStats,                                 
                                     stats = Stats } = State) ->
    NStats = build_comment(State, Stats),
    send_stats(SendStats, NStats),
    comm:send_local(Owner, {resolve_progress_report, self(), NStats}),    
    kill.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% HELPER
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

build_comment(#rr_resolve_state{ operation = Operation,
                                 feedback = {FBDest, _},
                                 feedback_resp = Resp }, Stats) ->
    Comment = case Operation of 
                  {key_upd, _} when Resp ->
                      "key_upd by feedback";
                  {key_upd, _} when not Resp andalso FBDest =:= nil ->
                      "key_upd without feedback"; 
                  {key_upd, _} when not Resp andalso FBDest =/= nil -> 
                      ["key_upd with feedback to ", FBDest];
                  {key_upd_dest, Dest, _} -> 
                      ["key_upd_dest with", Dest]
              end,
    Stats#resolve_stats{ comment = Comment }.

-spec send_feedback(feedback(), rrepair:round()) -> ok.
send_feedback({nil, _}, _) -> ok;
send_feedback({_, []}, _) -> ok;
send_feedback({Dest, Items}, Round) ->
    comm:send(Dest, {request_resolve, Round, {key_upd, Items}, [feedback_response]}).

-spec send_stats(nil | comm:mypid(), stats()) -> ok.
send_stats(nil, _) -> ok;
send_stats(SendStats, Stats) ->
    comm:send(SendStats, {resolve_stats, Stats}).

-spec print_resolve_stats(stats()) -> [any()].
print_resolve_stats(Stats) ->
    FieldNames = record_info(fields, resolve_stats),
    Res = util:for_to_ex(1, length(FieldNames), 
                         fun(I) ->
                                 {lists:nth(I, FieldNames), erlang:element(I + 1, Stats)}
                         end),    
    [erlang:element(1, Stats), lists:flatten(lists:reverse(Res))].

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% STARTUP
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% @doc init module
-spec init(state()) -> state().
init(State) ->
    comm:send_local(State#rr_resolve_state.dhtNodePid, {get_state, comm:this(), my_range}),
    State.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

-spec start(Round, Operation, Options) -> {ok, MyPid} when
      is_subtype(Round,     rrepair:round()),                                                        
      is_subtype(Operation, operation()),
      is_subtype(Options,   options()),
      is_subtype(MyPid,     pid()).
start(Round, Operation, Options) ->        
    FBDest = proplists:get_value(feedback, Options, nil),
    FBResp = proplists:get_value(feedback_response, Options, false),
    StatsDest = proplists:get_value(send_stats, Options, nil),
    State = #rr_resolve_state{ ownerLocalPid = self(), 
                               ownerRemotePid = comm:this(), 
                               dhtNodePid = pid_groups:get_my(dht_node),
                               operation = Operation,
                               stats = #resolve_stats{ round = Round },
                               feedback = {FBDest, []},
                               feedback_resp = FBResp,
                               send_stats = StatsDest },    
    gen_component:start(?MODULE, fun ?MODULE:on/2, State, []).
