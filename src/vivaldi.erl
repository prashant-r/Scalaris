%  @copyright 2009-2010 Konrad-Zuse-Zentrum fuer Informationstechnik Berlin

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

%% @author Thorsten Schuett <schuett@zib.de>
%% @doc Vivaldi is a network coordinate system.
%% @end
%% @reference Frank Dabek, Russ Cox, Frans Kaahoek, Robert Morris. <em>
%% Vivaldi: A Decentralized Network Coordinate System</em>. SigComm 2004.
%% @reference Jonathan Ledlie, Peter Pietzuch, Margo Seltzer. <em>Stable
%% and Accurate Network Coordinates</em>. ICDCS 2006.
%% @version $Id$
-module(vivaldi).
-author('schuett@zib.de').
-vsn('$Id$').

-behaviour(gen_component).

-include("scalaris.hrl").

-export([start_link/1]).

% functions gen_component, the trigger and the config module use
-export([init/1, on_startup/2, on/2,
         activate/0,
         get_base_interval/0, check_config/0]).

% helpers for creating getter messages:
-export([get_coordinate/0, get_coordinate/1]).

-ifdef(with_export_type_support).
-export_type([error/0, latency/0, network_coordinate/0]).
-endif.

% vivaldi types
-type(network_coordinate() :: [float()]).
-type(error() :: float()).
-type(latency() :: number()).

% state of the vivaldi loop
-type(state_init() :: {network_coordinate(), error(), trigger:state()}).
-type(state_uninit() :: {uninit, QueuedMessages::msg_queue:msg_queue(),
                         TriggerState :: trigger:state()}).
%% -type(state() :: state_init() | state_uninit()).

% accepted messages of vivaldi processes
-type(message() ::
    {trigger} |
    {cy_cache, RandomNodes::[node:node_type()]} |
    {vivaldi_shuffle, SourcePid::comm:mypid(), network_coordinate(), error()} |
    {update_vivaldi_coordinate, latency(), {network_coordinate(), error()}} |
    {get_coordinate, comm:mypid()} |
    {web_debug_info, Requestor::comm:erl_local_pid()}).

%% @doc Sends an initialization message to the node's vivaldi process.
-spec activate() -> ok.
activate() ->
    Pid = pid_groups:get_my(vivaldi),
    comm:send_local(Pid, {init_vivaldi}).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% Helper functions that create and send messages to nodes requesting information.
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% @doc Sends a response message to a request for the vivaldi coordinate.
-spec msg_get_coordinate_response(comm:mypid(), network_coordinate(), error()) -> ok.
msg_get_coordinate_response(Pid, Coordinate, Confidence) ->
    comm:send(Pid, {vivaldi_get_coordinate_response, Coordinate, Confidence}).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% Getters
%
% Functions that other processes can call to receive information from the
% vivaldi process
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% @doc Sends a (local) message to the vivaldi process of the requesting
%%      process' group asking for the current coordinate and confidence.
%%      see on({get_coordinate, Pid}, State) and
%%      msg_get_coordinate_response/3
-spec get_coordinate() -> ok.
get_coordinate() ->
    get_coordinate(comm:this()).

%% @doc Sends a (local) message to the vivaldi process of the requesting
%%      process' group asking for the current coordinate and confidence to
%%      be send to Pid.
%%      see on({get_coordinate, Pid}, State) and
%%      msg_get_coordinate_response/3
-spec get_coordinate(comm:mypid()) -> ok.
get_coordinate(Pid) ->
    VivaldiPid = pid_groups:get_my(vivaldi),
    comm:send_local(VivaldiPid, {get_coordinate, Pid}).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% Startup
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

-spec start_link(pid_groups:groupname()) -> {ok, pid()}.
start_link(DHTNodeGroup) ->
    Trigger = config:read(vivaldi_trigger),
    gen_component:start_link(?MODULE, Trigger, [{pid_groups_join_as, DHTNodeGroup, vivaldi}]).

-spec init(module()) -> {'$gen_component', [{on_handler, Handler::on_startup}], State::state_uninit()}.
init(Trigger) ->
    TriggerState = trigger:init(Trigger, ?MODULE),
    gen_component:change_handler({uninit, msg_queue:new(), TriggerState},
                                 on_startup).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% Message Loop
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% @doc Message handler during start up phase (will change to on/2 when a
%%      'init_vivaldi' message is received).
-spec on_startup(message(), state_uninit()) -> state_uninit();
                ({init_vivaldi}, state_uninit()) -> {'$gen_component', [{on_handler, Handler::on}], State::state_init()}.
on_startup({init_vivaldi}, {uninit, QueuedMessages, TriggerState}) ->
    TriggerState2 = trigger:now(TriggerState),
    msg_queue:send(QueuedMessages),
    gen_component:change_handler({random_coordinate(), 1.0, TriggerState2},
                                 on);

on_startup(Msg, {uninit, QueuedMessages, TriggerState}) ->
    {uninit, msg_queue:add(QueuedMessages, Msg), TriggerState}.

%% @doc Message handler when the module is fully initialized.
-spec on(message(), state_init()) -> state_init().
on({trigger}, {Coordinate, Confidence, TriggerState} ) ->
    % start new vivaldi shuffle
    %io:format("{start_vivaldi_shuffle}: ~p~n", [get_local_cyclon_pid()]),
    NewTriggerState = trigger:next(TriggerState),
    cyclon:get_subset_rand(1),
    {Coordinate, Confidence, NewTriggerState};

% ignore empty node list from cyclon
on({cy_cache, []}, State)  ->
    State;

% got random node from cyclon
on({cy_cache, [Node] = _Cache},
   {Coordinate, Confidence, _TriggerState} = State) ->
    %io:format("~p~n",[_Cache]),
    % do not exchange states with itself
    case node:is_me(Node) of
        false ->
            comm:send_to_group_member(node:pidX(Node), vivaldi,
                                         {vivaldi_shuffle, comm:this(),
                                          Coordinate, Confidence});
        true -> ok
    end,
    State;

on({vivaldi_shuffle, SourcePid, RemoteCoordinate, RemoteConfidence}, State) ->
    %io:format("{shuffle, ~p, ~p}~n", [RemoteCoordinate, RemoteConfidence]),
    vivaldi_latency:measure_latency(SourcePid, RemoteCoordinate, RemoteConfidence),
    State;

on({update_vivaldi_coordinate, Latency, {RemoteCoordinate, RemoteConfidence}},
   {Coordinate, Confidence, TriggerState}) ->
    %io:format("latency is ~pus~n", [Latency]),
    {NewCoordinate, NewConfidence} =
        try
            update_coordinate(RemoteCoordinate, RemoteConfidence,
                              Latency, Coordinate, Confidence)
        catch
            % ignore any exceptions, e.g. badarith
            error:_ -> {Coordinate, Confidence}
        end,
    {NewCoordinate, NewConfidence, TriggerState};

on({get_coordinate, Pid}, {Coordinate, Confidence, _TriggerState} = State) ->
    msg_get_coordinate_response(Pid, Coordinate, Confidence),
    State;

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% Web interface
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

on({web_debug_info, Requestor},
   {Coordinate, Confidence, _TriggerState} = State) ->
    KeyValueList =
        [{"coordinate", lists:flatten(io_lib:format("~p", [Coordinate]))},
         {"confidence", Confidence}],
    comm:send_local(Requestor, {web_debug_info_reply, KeyValueList}),
    State.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% Helpers
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

-spec random_coordinate() -> network_coordinate().
random_coordinate() ->
    Dim = config:read(vivaldi_dimensions),
    % note: network coordinates are float vectors!
    [ float(crypto:rand_uniform(1, 10)) || _ <- lists:seq(1, Dim) ].

-spec update_coordinate(network_coordinate(), error(), latency(),
                         network_coordinate(), error()) ->
                            {network_coordinate(), error()}.
update_coordinate(Coordinate, _RemoteError, _Latency, Coordinate, Error) ->
    % same coordinate
    {Coordinate, Error};
update_coordinate(RemoteCoordinate, RemoteError, Latency, Coordinate, Error) ->
    Cc = 0.5, Ce = 0.5,
    % sample weight balances local and remote error
    W = Error/(Error + RemoteError),
    % relative error of sample
    Es = abs(mathlib:euclideanDistance(RemoteCoordinate, Coordinate) - Latency) / Latency,
    % update weighted moving average of local error
    Error1 = Es * Ce * W + Error * (1 - Ce * W),
    % update local coordinates
    Delta = Cc * W,
    %io:format('expected latency: ~p~n', [mathlib:euclideanDist(Coordinate, _RemoteCoordinate)]),
    C1 = mathlib:u(mathlib:vecSub(Coordinate, RemoteCoordinate)),
    C2 = mathlib:euclideanDistance(Coordinate, RemoteCoordinate),
    C3 = Latency - C2,
    C4 = C3 * Delta,
    Coordinate1 = mathlib:vecAdd(Coordinate, mathlib:vecMult(C1, C4)),
    %io:format("new coordinate ~p and error ~p~n", [Coordinate1, Error1]),
    {Coordinate1, Error1}.


%%% Miscellaneous

%% @doc Checks whether config parameters of the vivaldi process exist and are
%%      valid.
-spec check_config() -> boolean().
check_config() ->
    config:is_atom(vivaldi_trigger) and

    config:is_integer(vivaldi_interval) and
    config:is_greater_than(vivaldi_interval, 0) and

    config:is_integer(vivaldi_dimensions) and
    config:is_greater_than_equal(vivaldi_dimensions, 2).

%% @doc Gets the vivaldi interval set in scalaris.cfg.
-spec get_base_interval() -> pos_integer().
get_base_interval() ->
    config:read(vivaldi_interval).
