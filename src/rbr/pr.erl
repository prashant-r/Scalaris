% @copyright 2014 Zuse Institute Berlin,

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

%% @author Florian Schintke <schintke@zib.de>
%% @doc    Abstract data type for a paxos round (pr).
%% @end
%% @version $Id$
-module(pr).
-author('schintke@zib.de').
-vsn('$Id:$ ').

%-define(TRACE(X,Y), io:format(X,Y)).
-define(TRACE(X,Y), ok).
-include("scalaris.hrl").

-export([new/2]).
-export([get_r/1]).
-export([get_id/1]).
-export([get_wf/1, set_wf/2]).
%% let users retrieve their smallest possible round for fast_write on
%% entry creation.
-export([smallest_round/1]).

%% let users retrieve their uid from an assigned round number.

%% let users retrieve their smallest possible round for fast_write on
%% entry creation.
%%-export([smallest_round/1]).

-ifdef(with_export_type_support).
-export_type([pr/0]).
-endif.

%% pr() has to be unique for this key system wide
%% pr() has to be comparable with < and =<
%% if the caller process may handle more than one request at a time for the
%% same key, it has to be unique for each request.
%% for example
%% -type pr() :: {pos_integer(), comm:mypid(), none}.
%% -type pr() :: {pos_integer(), {dht_node_id(), lease_epoch()}, none}.
-type pr() ::
        {non_neg_integer(),         %% the actual round number
         any(),                     %% the clients identifier to make unique
         %% the used write_filter for write through and its parameters
         none | prbr:write_filter() %% ...
        }.

-spec new(non_neg_integer(), any()) -> pr().
new(Counter, ProposerUID) -> {Counter, ProposerUID, none}.

-spec get_r(pr()) -> non_neg_integer().
get_r(RwId) -> element(1, RwId).

-spec get_id(pr()) -> any().
get_id(RwId) -> element(2, RwId).

-spec get_wf(pr()) -> none | prbr:write_filter().
get_wf(RwId) -> element(3, RwId).

-spec set_wf(pr(), none | prbr:write_filter()) -> pr().
set_wf(R, WF) -> setelement(3, R, WF).

%% As the round number contains the client's pid, they are still
%% unique.  Two clients using their smallest_round for a fast write
%% concurrently are separated, because we do not use plain Paxos, but
%% assign a succesful writer immediately the next round_number for a
%% follow up fast_write by increasing our read_round already on the
%% write.  So, the smallest_round of the second client becomes invalid
%% when the first one writes.  In consequence, at most one proposer
%% can perform a successful fast_write with its smallest_round. Voila!
-spec smallest_round(comm:mypid()) -> pr:pr().
smallest_round(Pid) -> new(0, Pid).

