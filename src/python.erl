%%% Copyright (c) 2009-2012, Dmitry Vasiliev <dima@hlabs.org>
%%% All rights reserved.
%%% 
%%% Redistribution and use in source and binary forms, with or without
%%% modification, are permitted provided that the following conditions are met:
%%% 
%%%  * Redistributions of source code must retain the above copyright notice,
%%%    this list of conditions and the following disclaimer.
%%%  * Redistributions in binary form must reproduce the above copyright
%%%    notice, this list of conditions and the following disclaimer in the
%%%    documentation and/or other materials provided with the distribution.
%%%  * Neither the name of the copyright holders nor the names of its
%%%    contributors may be used to endorse or promote products derived from
%%%    this software without specific prior written permission. 
%%% 
%%% THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
%%% AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
%%% IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
%%% ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE
%%% LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
%%% CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
%%% SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
%%% INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
%%% CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
%%% ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
%%% POSSIBILITY OF SUCH DAMAGE.

-module(python).

-behaviour(gen_server).

-export([
    start/0,
    start/1,
    start_link/0,
    start_link/1,
    stop/1,
    call/4,
    cast/4
    ]).

-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
    ]).

-record(state, {
    port :: port(),
    id = 0 :: non_neg_integer(),
    requests = dict:new() :: dict()
    }).

-define(START_TIMEOUT, 15000).
-define(CALL_TIMEOUT, 15000).


start() ->
    start([]).

-spec start(Options) -> Result when
    Options :: [Option],
    Option :: nouse_stdio
        | {packet, 1 | 2 | 4}
        | {python, Python :: string()}
        | {python_path, Path :: string()}
        | {env, [{Name :: string(), Value :: string() | false}]},
    Result :: {ok, pid()} | {error, term()}.

start(Options) when is_list(Options) ->
    gen_server:start(?MODULE, Options, [{timeout, ?START_TIMEOUT}]).


start_link() ->
    start_link([]).

start_link(Options) when is_list(Options) ->
    gen_server:start_link(?MODULE, Options, [{timeout, ?START_TIMEOUT}]).


stop(InstanceId) when is_pid(InstanceId) ->
    gen_server:cast(InstanceId, stop).


call(InstanceId, Module, Function, Args) when is_pid(InstanceId),
        is_atom(Module), is_atom(Function), is_list(Args) ->
    case gen_server:call(InstanceId, {call, Module, Function, Args}) of
        {ok, Result} ->
            Result;
        {error, Error} ->
            erlang:error(Error)
    end.


cast(InstanceId, Module, Function, Args) when is_pid(InstanceId),
        is_atom(Module), is_atom(Function), is_list(Args) ->
    gen_server:cast(InstanceId, {call, Module, Function, Args}).


%%%
%%% Behaviour callbacks
%%%

init(Options) when is_list(Options) ->
    % FIXME: Cleanup option parsing and command line construction
    Stdio = case proplists:get_value(nouse_stdio, Options, false) of
        true ->
            nouse_stdio;
        false ->
            use_stdio
    end,
    Packet = case proplists:get_value(packet, Options, 4) of
        1 ->
            1;
        2 ->
            2;
        4 ->
            4
    end,
    Python = proplists:get_value(python, Options, "python"),
    Env = proplists:get_value(env, Options, []),
    % TODO: Check for errors
    PrivPath = filename:join(code:priv_dir(erlport), "python"),
    Env2 = case proplists:get_value(python_path, Options) of
        undefined ->
            [{"PYTHONPATH", PrivPath} | Env];
        PythonPath ->
            [{"PYTHONPATH", PrivPath ++ ":" ++ PythonPath}
                | proplists:delete("PYTHONPATH", Env)]
    end,
    % TODO: Add custom args?
    Path = lists:concat([Python, " -u -m erlport.cli --packet=", Packet,
        " --", Stdio]),
    Port = open_port({spawn, Path},
        [{packet, Packet}, binary, Stdio, hide, {env, Env2}]),
    {ok, #state{port=Port}}.


handle_call({call, Module, Function, Args}, From, State=#state{port=Port,
        id=Id, requests=Requests})
        when is_atom(Module), is_atom(Function), is_list(Args) ->
    Timer = erlang:send_after(?CALL_TIMEOUT, self(), {timeout, From}),
    NewRequests = dict:store(Id, {From, Timer}, Requests),
    Request = {'S', Id, Module, Function, Args},
    true = port_command(Port, term_to_binary(Request)),
    % TODO: Optimize Id generation
    % TODO: Cleanup requests storage
    {noreply, State#state{id=Id + 1, requests=NewRequests}};
handle_call(Request, From, State) ->
    {reply, {error, {badarg, ?MODULE, Request, From}}, State}.


handle_cast({call, Module, Function, Args}, State=#state{port=Port})
        when is_atom(Module), is_atom(Function), is_list(Args) ->
    Request = {'A', Module, Function, Args},
    true = port_command(Port, term_to_binary(Request)),
    {noreply, State};
handle_cast(stop, State) ->
    {stop, normal, State};
handle_cast(_Request, State) ->
    {noreply, State}.


handle_info({Port, {data, Data}}, State=#state{port=Port,
        requests=Requests}) ->
    try binary_to_term(Data) of
        {'R', Id, Result} ->
            NewState = case dict:find(Id, Requests) of
                {ok, {From, Timer}} ->
                    erlang:cancel_timer(Timer),
                    gen_server:reply(From, Result),
                    State#state{requests=dict:erase(Id, Requests)};
                error ->
                    State
            end,
            {noreply, NewState};
        {'A', Module, Function, Args} when is_atom(Module), is_atom(Function),
                is_list(Args) ->
            proc_lib:spawn(fun () ->
                apply(Module, Function, Args)
                end),
            {noreply, State};
        {'S', Id, Module, Function, Args} when is_atom(Module),
                is_atom(Function), is_list(Args) ->
            proc_lib:spawn(fun () ->
                Result = try {ok, apply(Module, Function, Args)}
                    catch
                        Class:Reason ->
                            {error, Class, Reason, erlang:get_stacktrace()}
                    end,
                Response = {'R', Id, Result},
                true = port_command(Port, term_to_binary(Response))
                end),
            {noreply, State}
    catch
        error:badarg ->
            {noreply, State}
    end;
handle_info({timeout, From}, State) ->
    gen_server:reply(From, {error, timeout}),
    {noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.


terminate(_Reason, _State) ->
    ok.


code_change(_OldVsn, State, _Extra) ->
    {ok, State}.
