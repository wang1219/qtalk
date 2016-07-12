%%%----------------------------------------------------------------------
%%% File    : ezlib.erl
%%% Author  : Alexey Shchepin <alexey@process-one.net>
%%% Purpose : Interface to zlib
%%% Created : 19 Jan 2006 by Alexey Shchepin <alexey@process-one.net>
%%%
%%%
%%% ezlib, Copyright (C) 2002-2015   ProcessOne
%%%
%%% This program is free software; you can redistribute it and/or
%%% modify it under the terms of the GNU General Public License as
%%% published by the Free Software Foundation; either version 2 of the
%%% License, or (at your option) any later version.
%%%
%%% This program is distributed in the hope that it will be useful,
%%% but WITHOUT ANY WARRANTY; without even the implied warranty of
%%% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
%%% General Public License for more details.
%%%
%%% You should have received a copy of the GNU General Public License
%%% along with this program; if not, write to the Free Software
%%% Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA
%%% 02111-1307 USA
%%%
%%%----------------------------------------------------------------------

-module(ezlib).

-author('alexey@process-one.net').

-behaviour(gen_server).

-export([start_link/0, enable_zlib/2,
	 disable_zlib/1, send/2, recv/2, recv/3, recv_data/2,
	 setopts/2, sockname/1, peername/1, get_sockmod/1,
	 controlling_process/2, close/1]).

%% Internal exports, call-back functions.
-export([init/1, handle_call/3, handle_cast/2,
	 handle_info/2, code_change/3, terminate/2]).

-define(DEFLATE, 1).

-define(INFLATE, 2).

-record(zlibsock, {sockmod :: atom(),
                   socket :: inet:socket(),
                   zlibport :: port()}).

-type zlib_socket() :: #zlibsock{}.

-export_type([zlib_socket/0]).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [],
			  []).

init([]) ->
    case load_driver() of
        ok ->
            {ok, []};
        {error, Reason} ->
            {stop, Reason}
    end.

%%% --------------------------------------------------------
%%% The call-back functions.
%%% --------------------------------------------------------

handle_call(_, _, State) -> {noreply, State}.

handle_cast(_, State) -> {noreply, State}.

handle_info({'EXIT', Port, Reason}, Port) ->
    {stop, {port_died, Reason}, Port};
handle_info({'EXIT', _Pid, _Reason}, Port) ->
    {noreply, Port};
handle_info(_, State) -> {noreply, State}.

code_change(_OldVsn, State, _Extra) -> {ok, State}.

terminate(_Reason, _State) ->
    ok.

-spec enable_zlib(atom(), inet:socket()) -> {ok, zlib_socket()} | {error, any()}.

enable_zlib(SockMod, Socket) ->
    case load_driver() of
        ok ->
            Port = open_port({spawn, "ezlib_drv"},
                             [binary]),
%%			error_logger:error_msg("open port zlib  ~p ~n",[self()]),	
            {ok,
             #zlibsock{sockmod = SockMod, socket = Socket,
                       zlibport = Port}};
        Err ->
            Err
    end.

-spec disable_zlib(zlib_socket()) -> {atom(), inet:socket()}.

disable_zlib(#zlibsock{sockmod = SockMod,
		       socket = Socket, zlibport = Port}) ->
    port_close(Port), {SockMod, Socket}.

-spec recv(zlib_socket(), number()) -> {ok, binary()} | {error, any()}.

recv(Socket, Length) -> recv(Socket, Length, infinity).

-spec recv(zlib_socket(), number(), timeout()) -> {ok, binary()} |
                                                  {error, any()}.

recv(#zlibsock{sockmod = SockMod, socket = Socket} =
	 ZlibSock,
     Length, Timeout) ->
    case SockMod:recv(Socket, Length, Timeout) of
      {ok, Packet} -> recv_data(ZlibSock, Packet);
      {error, _Reason} = Error -> Error
    end.

-spec recv_data(zlib_socket(), iodata()) -> {ok, binary()} | {error, any()}.

recv_data(#zlibsock{sockmod = SockMod,
		    socket = Socket} =
	      ZlibSock,
	  Packet) ->
    case SockMod of
      gen_tcp -> recv_data2(ZlibSock, Packet);
      _ ->
	  case SockMod:recv_data(Socket, Packet) of
	    {ok, Packet2} -> recv_data2(ZlibSock, Packet2);
	    Error -> Error
	  end
    end.

recv_data2(ZlibSock, Packet) ->
    case catch recv_data1(ZlibSock, Packet) of
      {'EXIT', Reason} -> {error, Reason};
      Res -> Res
    end.

recv_data1(#zlibsock{zlibport = Port} = _ZlibSock,
	   Packet) ->
    case port_control(Port, ?INFLATE, Packet) of
      <<0, In/binary>> -> {ok, In};
      <<1, Error/binary>> -> {error, (Error)}
    end.

-spec send(zlib_socket(), iodata()) -> ok | {error, binary() | inet:posix()}.

send(#zlibsock{sockmod = SockMod, socket = Socket,
	       zlibport = Port},
     Packet) ->
    case catch port_control(Port, ?DEFLATE, Packet) of
      <<0, Out/binary>> -> SockMod:send(Socket, Out);
      <<1, Error/binary>> -> {error, (Error)};
	  _ ->
	  	{error,(<<"open_port error">>)}
    end.

-spec setopts(zlib_socket(), list()) -> ok | {error, inet:posix()}.

setopts(#zlibsock{sockmod = SockMod, socket = Socket},
	Opts) ->
    case SockMod of
      gen_tcp -> inet:setopts(Socket, Opts);
      _ -> SockMod:setopts(Socket, Opts)
    end.

-spec sockname(zlib_socket()) -> {ok, {inet:ip_address(), inet:port_number()}} |
                                 {error, inet:posix()}.

sockname(#zlibsock{sockmod = SockMod,
		   socket = Socket}) ->
    case SockMod of
      gen_tcp -> inet:sockname(Socket);
      _ -> SockMod:sockname(Socket)
    end.

-spec get_sockmod(zlib_socket()) -> atom().

get_sockmod(#zlibsock{sockmod = SockMod}) -> SockMod.

-spec peername(zlib_socket()) -> {ok, {inet:ip_address(), inet:port_number()}} |
                                 {error, inet:posix()}.

peername(#zlibsock{sockmod = SockMod,
		   socket = Socket}) ->
    case SockMod of
      gen_tcp -> inet:peername(Socket);
      _ -> SockMod:peername(Socket)
    end.

-spec controlling_process(zlib_socket(), pid()) -> ok | {error, atom()}.

controlling_process(#zlibsock{sockmod = SockMod,
			      socket = Socket},
		    Pid) ->
    SockMod:controlling_process(Socket, Pid).

-spec close(zlib_socket()) -> true.

close(#zlibsock{sockmod = SockMod, socket = Socket,
		zlibport = Port}) ->
%%	error_logger:error_msg("close port zlib close ~p ~n",[self()]),	
    SockMod:close(Socket), port_close(Port).

get_so_path() ->
    EbinDir = filename:dirname(code:which(?MODULE)),
    AppDir = filename:dirname(EbinDir),
    filename:join([AppDir, "priv", "lib"]).

load_driver() ->
    case erl_ddll:load_driver(get_so_path(), ezlib_drv) of
        ok ->
            ok;
        {error, already_loaded} ->
            ok;
        {error, ErrorDesc} = Err ->
            error_logger:error_msg("failed to load zlib driver: ~s~n",
                                   [erl_ddll:format_error(ErrorDesc)]),
            Err
    end.