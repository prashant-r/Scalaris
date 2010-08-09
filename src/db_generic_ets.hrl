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
%% @doc    generic db code for ets
%% @end
%% @version $Id$

% Note: this include must be included in files including this file!
%% -include("scalaris.hrl").

-include("db_common.hrl").

%% @doc Gets an entry from the DB. If there is no entry with the given key,
%%      an empty entry will be returned.
get_entry(State, Key) ->
    {_Exists, Result} = get_entry2(State, Key),
    Result.

%% @doc Gets an entry from the DB. If there is no entry with the given key,
%%      an empty entry will be returned. The first component of the result
%%      tuple states whether the value really exists in the DB.
get_entry2({DB, _CKInt, _CKDB}, Key) ->
%%    Start = erlang:now(),
    Result = case ?ETS:lookup(DB, Key) of
                 [Entry] -> {true, Entry};
                 []      -> {false, db_entry:new(Key)}
             end,
%%     Stop = erlang:now(),
%%     Span = timer:now_diff(Stop, Start),
%%     case ?ETS:lookup(profiling, db_read_lookup) of
%%         [] ->
%%             ?ETS:insert(profiling, {db_read_lookup, Span});
%%         [{_, Sum}] ->
%%             ?ETS:insert(profiling, {db_read_lookup, Sum + Span})
%%     end,
    Result.

%% @doc Inserts a complete entry into the DB.
set_entry(State = {DB, CKInt, CKDB}, Entry) ->
    ?ETS:insert(DB, Entry),
    case intervals:in(db_entry:get_key(Entry), CKInt) of
        false -> ok;
        _     -> ?CKETS:insert(CKDB, {db_entry:get_key(Entry)})
    end,
    State.

%% @doc Updates an existing (!) entry in the DB.
%%      TODO: use ets:update_element here?
update_entry(State, Entry) ->
    set_entry(State, Entry).

%% @doc Removes all values with the given entry's key from the DB.
delete_entry(State = {DB, CKInt, CKDB}, Entry) ->
    ?ETS:delete(DB, db_entry:get_key(Entry)),
    case intervals:in(db_entry:get_key(Entry), CKInt) of
        false -> ok;
        _     -> ?CKETS:insert(CKDB, {db_entry:get_key(Entry)})
    end,
    State.

%% @doc returns the number of stored keys
get_load({DB, _CKInt, _CKDB}) ->
    ?ETS:info(DB, size).

%% @doc adds keys
add_data(State = {DB, CKInt, CKDB}, Data) ->
    case intervals:is_empty(CKInt) of
        true -> ok;
        _    -> [?CKETS:insert(CKDB, {db_entry:get_key(Entry)}) ||
                   Entry <- Data,
                   intervals:in(db_entry:get_key(Entry), CKInt)]
    end,
    ?ETS:insert(DB, Data),
    State.

%% @doc Splits the database into a database (first element) which contains all
%%      keys in MyNewInterval and a list of the other values (second element).
%%      Note: removes all keys not in MyNewInterval from the list of changed
%%      keys!
split_data(State = {DB, _CKInt, CKDB}, MyNewInterval) ->
    F = fun (DBEntry, HisList) ->
                case intervals:in(db_entry:get_key(DBEntry), MyNewInterval) of
                    true -> HisList;
                    _    -> ?ETS:delete(DB, db_entry:get_key(DBEntry)),
                            ?CKETS:delete(CKDB, db_entry:get_key(DBEntry)),
                            case db_entry:is_empty(DBEntry) of
                                false -> [DBEntry | HisList];
                                _     -> HisList
                            end
                end
        end,
    HisList = ?ETS:foldl(F, [], DB),
    {State, HisList}.

%% @doc Get key/value pairs in the given range.
get_range_kv({DB, _CKInt, _CKDB}, Interval) ->
    F = fun (DBEntry, Data) ->
                case (not db_entry:is_empty(DBEntry)) andalso
                         intervals:in(db_entry:get_key(DBEntry), Interval) of
                    true -> [{db_entry:get_key(DBEntry),
                              db_entry:get_value(DBEntry)} | Data];
                    _    -> Data
                end
        end,
    ?ETS:foldl(F, [], DB).

%% @doc Get key/value/version triples of non-write-locked entries in the given range.
get_range_kvv({DB, _CKInt, _CKDB}, Interval) ->
    F = fun (DBEntry, Data) ->
                case (not db_entry:is_empty(DBEntry)) andalso
                         (not db_entry:get_writelock(DBEntry)) andalso
                         intervals:in(db_entry:get_key(DBEntry), Interval) of
                    true -> [{db_entry:get_key(DBEntry),
                              db_entry:get_value(DBEntry),
                              db_entry:get_version(DBEntry)} | Data];
                    _    -> Data
                end
        end,
    ?ETS:foldl(F, [], DB).

%% @doc Gets db_entry objects in the given range.
get_range_entry({DB, _CKInt, _CKDB}, Interval) ->
    F = fun (DBEntry, Data) ->
                 case (not db_entry:is_empty(DBEntry)) andalso
                          intervals:in(db_entry:get_key(DBEntry), Interval) of
                     true -> [DBEntry | Data];
                     _    -> Data
                 end
        end,
    ?ETS:foldl(F, [], DB).
