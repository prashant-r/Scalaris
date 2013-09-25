%% @copyright 2007-2013 Zuse Institute Berlin

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

%% @author Jan Fajerski <fajerski@informatik.hu-berlin.de>
%% @doc Map Reduce helper functions
%%      this is part of the dht node
%%         
%% @end
%% @version $Id$
-module(mr).
-author('fajerski@informatik.hu-berlin.de').
-vsn('$Id$ ').

-define(TRACE(X, Y), io:format(X, Y)).

-export([
        on/2
        ]).

-include("scalaris.hrl").

-type(mr_phase() :: {map | reduce,
                     {erlanon | jsanon, binary()}}).

-type(mr_option() :: {atom(), term()}).

-type(mr_job_description() :: {[mr_phase()], [mr_option()]}).

-type(message() :: {mr, init, Client::comm:mypid(), JobId::nonempty_string(),
                    JobSpec::mr_job_description()}
                   | any()).

-spec on(message(), dht_node_state:state()) -> dht_node_state:state().
on({mr, init, Client, JobId, Job}, State) ->
    %% this is the inital message
    %% it creates a JobID and starts the master process,
    %% which in turn starts the worker supervisor on all nodes.
    ?TRACE("mr: ~p~n received init message from ~p~n starting job ~p~n",
           [comm:this(), Client, Job]),
    JobDesc = job_desc({JobId, Client, Job}),
    SupDHT = pid_groups:get_my(sup_dht_node),
    %% TODO handle failed starts
    supervisor:start_child(SupDHT, JobDesc),
    State;

on({bulk_distribute, _Id, _Interval,
    {mr, job, JobId, Master, Client, Job, InitalData}, _Parents}, State) ->
    ?TRACE("mr_~s on ~p: received job with initial data: ~p...~n",
           [JobId, self(), hd(InitalData)]),
    %% @doc
    %% this message starts the worker supervisor and adds a job specific state
    %% to the dht node
    JobState = mr_state:new(JobId, Client, Master, InitalData, Job),
    %% send acc to master
    %% comm:send(Master, {mr, ack_init, Range}),
    %% start worker thread for first phase
    Range = lists:foldl(fun({I, _SlideOp}, AccIn) -> intervals:union(I, AccIn) end,
                        dht_node_state:get(State, my_range),
                        dht_node_state:get(State, db_range)),
    work_on_phase(JobId, JobState, Range),
    dht_node_state:set_mr_state(State, JobId, JobState);

on({mr, phase_result, JobId, {work_done, Data}, Range}, State) ->
    ?TRACE("mr_~s on ~p: received phase results: ~p...~ndistributing...~n",
           [JobId, self(), hd(Data)]),
    Ref = uid:get_global_uid(),
    NewMRState = mr_state:set_acked(dht_node_state:get_mr_state(State, JobId), {Ref, []}),
    case mr_state:is_last_phase(NewMRState) of
        false ->
            Reply = comm:reply_as(comm:this(), 4, {mr, next_phase_data_ack,
                                                   {JobId, Ref, Range}, '_'}),
            bulkowner:issue_bulk_distribute(Ref, dht_node,
                                            5, {mr, next_phase_data, JobId, Reply, '_'},
                                            Data);
        _ ->
            ?TRACE("jobs last phase done...sending to client~n", []),
            Master = mr_state:get(NewMRState, master),
            comm:send(Master, {mr, job_completed, Range}), 
            Client = mr_state:get(NewMRState, client),
            comm:send(Client, {mr_results, Data, Range, JobId})
    end,
    dht_node_state:set_mr_state(State, JobId, NewMRState);

on({bulk_distribute, _Id, Interval,
   {mr, next_phase_data, JobId, Source, Data}, _Parents}, State) ->
    NewMRState = mr_state:add_data_to_next_phase(dht_node_state:get_mr_state(State,
                                                                            JobId), 
                                                 Data),
    %% send ack with delivery interval
    comm:send(Source, Interval),
    dht_node_state:set_mr_state(State, JobId, NewMRState);

on({mr, next_phase_data_ack, {JobId, Ref, Range}, Interval}, State) ->
    NewMRState = mr_state:set_acked(dht_node_state:get_mr_state(State, JobId),
                                    {Ref, Interval}),
    case mr_state:is_acked_complete(NewMRState) of
        true ->
            Master = mr_state:get(NewMRState, master),
            comm:send(Master, {mr, phase_completed, Range}),
            ?TRACE("Phase complete...~p informing master~n", [self()]);
        false ->
            ?TRACE("~p is still waiting for phase to complete~n", [self()])
    end,
    dht_node_state:set_mr_state(State, JobId, NewMRState);

on({mr, next_phase, JobId}, State) ->
    %% io:format("master initiating next phase ~p~n~p",
    %%           [JobId, State]),
    MrState = mr_state:next_phase(dht_node_state:get_mr_state(State, JobId)),
    Range = lists:foldl(fun({I, _SlideOp}, AccIn) -> intervals:union(I, AccIn) end,
                        dht_node_state:get(State, my_range),
                        dht_node_state:get(State, db_range)),
    work_on_phase(JobId, MrState, Range),
    dht_node_state:set_mr_state(State, JobId, MrState);

on({mr, terminate_job, JobId}, State) ->
    dht_node_state:delete_mr_state(State, JobId);

on(Msg, State) ->
    ?TRACE("~p mr: unknown message ~p~n", [comm:this(), Msg]),
    State.

work_on_phase(JobId, MRState, MyRange) ->
    case mr_state:get_phase(MRState) of
        {_Round, _MoR, _FunTerm, []} ->
            case mr_state:is_last_phase(MRState) of
                false ->
                    Master = mr_state:get(MRState, master),
                    comm:send(Master, {mr, phase_completed, MyRange}),
                    ?TRACE("no data for phase...done...~p informs master~n", [self()]);
                _ ->
                    Client = mr_state:get(MRState, client),
                    comm:send(Client, {mr_results, [], MyRange})
            end;
        Phase ->
            Reply = comm:reply_as(comm:this(), 4, {mr, phase_result, JobId, '_',
                                                  MyRange}),
            comm:send_local(pid_groups:get_my(wpool), 
                            {do_work, Reply, Phase})
    end.

job_desc(Options) ->
    DHTNodeGroup = pid_groups:my_groupname(),
    {"mr_master_" ++ element(1, Options), {mr_master, start_link,
                                            [DHTNodeGroup, Options]}, transient,
      brutal_kill, worker, []}.
