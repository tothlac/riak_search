%% -------------------------------------------------------------------
%%
%% Copyright (c) 2007-2010 Basho Technologies, Inc.  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------

-module(merge_index_backend).
-export([start/2,stop/1,get/2,put/3,list/1,list_bucket/2,delete/2]).
-export([fold/3, drop/1, is_empty/1]).

-include_lib("eunit/include/eunit.hrl").
-include("riak_search.hrl").
% @type state() = term().
-record(state, {partition, pid}).

%% @spec start(Partition :: integer(), Config :: proplist()) ->
%%          {ok, state()} | {{error, Reason :: term()}, state()}
%% @doc Start this backend.
start(Partition, Config) ->
    DefaultRootPath = filename:join([".", "data", "merge_index"]),
    RootPath = proplists:get_value(merge_index_backend_root, Config, DefaultRootPath),
    Rootfile = filename:join([RootPath, integer_to_list(Partition)]),
    {ok, Pid} = merge_index:start_link(Rootfile, Config),
    {ok, #state { partition=Partition, pid=Pid }}.

%% @spec stop(state()) -> ok | {error, Reason :: term()}
stop(State) ->
    Pid = State#state.pid,
    ok = merge_index:stop(Pid).

%% @spec put(state(), BKey :: riak_object:bkey(), Val :: binary()) ->
%%         ok | {error, Reason :: term()}
%% @doc Route all commands through the object's value.
put(State, _BKey, ObjBin) ->
    Obj = binary_to_term(ObjBin),
    Command = riak_object:get_value(Obj),
    handle_command(State, Command).

handle_command(State, {index, Index, Field, Term, Value, Props}) ->
    handle_command(State, {index, Index, Field, Term, 0, 0, Value, Props, erlang:now()});

handle_command(State, {index, Index, Field, Term, SubType, SubTerm, Value, Props, Timestamp}) ->
    %% Put with properties.
    Pid = State#state.pid,
    merge_index:index(Pid, Index, Field, Term, SubType, SubTerm, Value, Props, Timestamp),
    ok;

handle_command(State, {index, Index, Field, Term, SubType, SubTerm, Value, Props}) ->
    %% io:format("Got a put: ~p ~p ~p~n", [BucketName, Value, Props]),
    %% Put with properties.
    Pid = State#state.pid,
    merge_index:index(Pid, Index, Field, Term, SubType, SubTerm, Value, Props, now()),
    ok;

handle_command(State, {init_stream, OutputPid, OutputRef}) ->
    %% Do some handshaking so that we only stream results from one partition/node.
    Partition = State#state.partition,
    OutputPid!{stream_ready, Partition, node(), OutputRef},
    ok;

handle_command(State, {stream, Index, Field, Term, SubType, StartSubTerm, EndSubTerm, OutputPid, OutputRef, Partition, Node, FilterFun}) ->
    Pid = State#state.pid,
    case Partition == State#state.partition andalso Node == node() of
        true ->
            %% Stream some results.
            merge_index:stream(Pid, Index, Field, Term, SubType, StartSubTerm, EndSubTerm, OutputPid, OutputRef, FilterFun);
        false ->
            %% The requester doesn't want results from this node, so
            %% ignore. This is a hack, to get around the fact that
            %% there is no way to send a put or other command to a
            %% specific v-node.
            ignore
    end,
    ok;

handle_command(State, {info, Index, Field, Term, OutputPid, OutputRef}) ->
    Pid = State#state.pid,
    {ok, Info} = merge_index:info(Pid, Index, Field, Term),
    Info1 = [{Term, node(), Count} || {_, Count} <- Info],
    OutputPid!{info_response, Info1, OutputRef},
    ok;

handle_command(State, {info_range, Index, Field, StartTerm, EndTerm, Size, OutputPid, OutputRef}) ->
    Pid = State#state.pid,
    {ok, Info} = merge_index:info_range(Pid, Index, Field, StartTerm, EndTerm, Size),
    Info1 = [{Term, node(), Count} || {Term, Count} <- Info],
    OutputPid!{info_response, Info1, OutputRef},
    ok;

handle_command(_State, Other) ->
    throw({unexpected_operation, Other}).



%% @spec get(state(), BKey :: riak_object:bkey()) ->
%%         {ok, Val :: binary()} | {error, Reason :: term()}
%% @doc Get the object stored at the given bucket/key pair. The merge
%% backend does not support key-based lookups, so always return
%% {error, notfound}.
get(_State, _BKey) ->
    {error, notfound}.

is_empty(State) ->
    ?PRINT(is_empty),
    Pid = State#state.pid,
    merge_index:is_empty(Pid).

fold(State, Fun, Acc) ->
    ?PRINT({fold, Fun, Acc}),
    Pid = State#state.pid,
    merge_index:fold(Pid, Fun, Acc).

drop(State) ->
    ?PRINT(drop),
    Pid = State#state.pid,
    merge_index:drop(Pid).

%% @spec delete(state(), BKey :: riak_object:bkey()) ->
%%          ok | {error, Reason :: term()}
%% @doc Writes are not supported.
delete(_State, _BKey) ->
    {error, not_supported}.

%% @spec list(state()) -> [{Bucket :: riak_object:bucket(),
%%                          Key :: riak_object:key()}]
%% @doc Get a list of all bucket/key pairs stored by this backend
list(_State) ->
    throw({error, not_supported}).


%% @spec list_bucket(state(), riak_object:bucket()) ->
%%           [riak_object:key()]
%% @doc Get a list of the keys in a bucket
list_bucket(_State, _Bucket) ->
    throw({error, not_supported}).
