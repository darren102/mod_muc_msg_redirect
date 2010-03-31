%%%----------------------------------------------------------------------
%%% File    : mod_muc_msg_redirect.erl
%%% Author  : Darren Ferguson <darren.ferguson@openband.net>
%%% Purpose : Send muc msg packets via xmlrpc to a listener
%%% Id      : $Id: mod_presence_redirect.erl
%%%----------------------------------------------------------------------

-module(mod_muc_msg_redirect).
-author('darren.ferguson@openband.net').
-version("0.5").

-behaviour(gen_mod).

% API for the module
-export([start/2,
         stop/1,
         muc_msg_send/3,
         packet_filter/1,
         receive_packet/4]).

% will only use for debugging purposes, will remove the line once finished
-define(ejabberd_debug, true).

% including the ejabberd main header file
-include("ejabberd.hrl").
-include("jlib.hrl").

-define(PROCNAME, ejabberd_mod_muc_msg_redirect).

% variable with _ i.e. _Opts will not bring a compiler unused error if not used
start(Host, Opts) ->
    % getting the list of servers that are associated with the module so we can determine
    % which one we need to send the xmlrpc request back too from this one
    S = gen_mod:get_opt(servers, Opts, "127.0.0.1"),
    F = fun(N) ->
       V = lists:nth(1, N),
       case V of
          Host ->
              true;
          _ ->
              false
       end
    end,
    Servers = lists:filter(F, S),
    % check if we received anything back from server variable
    case lists:member(Host, lists:nth(1, Servers)) of
         true ->
              Server = lists:nth(2, lists:nth(1, Servers));
         _ ->
              Server = "127.0.0.1"
    end,

    % parsing the host config incase it has been utilized instead of the module config portion
    Url = case ejabberd_config:get_local_option({mod_muc_msg_redirect_url , Host}) of
             undefined -> Server;
             U -> U
          end,
    Port = case ejabberd_config:get_local_option({mod_muc_msg_redirect_port , Host}) of
              undefined -> gen_mod:get_opt(port, Opts, 4560);
              P -> P
           end,
    Uri = case ejabberd_config:get_local_option({mod_muc_msg_redirect_uri , Host}) of
              undefined -> gen_mod:get_opt(uri, Opts, "/xmlrpc.php");
              UR -> UR
          end,
    Method = case ejabberd_config:get_local_option({mod_muc_msg_redirect_method , Host}) of
                undefined -> gen_mod:get_opt(method, Opts, "xmpp_node_muc.room_log");
                M -> M
             end,

    % adding hooks for the presence handlers so our function will be called
    ejabberd_hooks:add(user_send_packet, Host,
                       ?MODULE, muc_msg_send, 50),
    ejabberd_hooks:add(filter_packet, global,
                       ?MODULE, packet_filter, 50),
    CHost = string:concat("conference.", Host),
    % spawning a background process so we can use these variables later (erlang no global variables)
    register(gen_mod:get_module_proc(CHost, ?PROCNAME),
             spawn(mod_muc_msg_redirect, receive_packet, [Url, Port, Uri, Method])),
    ok.

stop(Host) ->
    % removing the hooks for the presence handlers when the server is stopped
    ejabberd_hooks:delete(user_send_packet, Host,
                          ?MODULE, muc_msg_send, 50),
    ejabberd_hooks:delete(filter_packet, Host,
                          ?MODULE, packet_filter, 50),
    CHost = string:concat("conference.", Host),
    Proc = gen_mod:get_module_proc(CHost, ?PROCNAME),
    Proc ! stop,
    ok.

% listener function that will send the packet with pertinent information
% F: From inside the packet
% T: To inside the packet
% P: the packet sent
receive_packet(Server, Port, Uri, Method) ->
    receive
        {F, T, P} ->
                Body = xml:get_path_s(P, [{elem, "body"}, cdata]),
                Subject = xml:get_path_s(P, [{elem, "subject"}, cdata]),
                xmlrpc:call(Server, Port, Uri,
                            {call, Method, [jlib:jid_to_string(F), jlib:jid_to_string(T), Subject, Body]});
        {R, S, Res, U, ST } ->
                xmlrpc:call(Server, Port, Uri,
                            {call, xmpp_node_muc.room_presence_update, [R, S, Res, U, ST]});
        stop ->
                exit(normal)
    end,
    receive_packet(Server, Port, Uri, Method).

% function called when we have a presence update and the user is staying online
muc_msg_send(From, To, Packet) ->
    {xmlelement, Name, Attrs, _Els} = Packet,
    Type = xml:get_attr_s("type", Attrs),
    if
       Name == "message", Type == "groupchat" ->
         Host = To#jid.lserver,
         Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
         Proc ! {From, To, Packet};
       true ->
         ok
    end,
    ok.

% function called for filter_packet, just trying to see what we are getting
packet_filter(Input = {From, To, Packet}) ->
   {xmlelement, Name, Attrs, _Els} = Packet,
   Type = xml:get_attr_s("type", Attrs),
   if
      Name == "presence" ->
         FRoom = From#jid.user,
         FServer = From#jid.server,
         % if the room does not exist yet in the muc_online_room then below will start the room
         case mnesia:dirty_read(muc_online_room, {FRoom, FServer}) of
            [] ->
                TRoom = To#jid.user,
                TServer = To#jid.server,
                case mnesia:dirty_read(muc_online_room, {TRoom, TServer}) of
                   [] ->
                     ok; % ignore since it is not an muc presence packet
                   _ ->
                     Resource = To#jid.resource,
                     Host = To#jid.lserver,
                     Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
                     if
                        Type == "unavailable" ->
                          Proc ! {TRoom, TServer, Resource, jlib:jid_to_string(From), Type};
                        true ->
                          Proc ! {TRoom, TServer, Resource, jlib:jid_to_string(From), "available"}
                     end
                end,
                ok;
	    _ ->
                ok
         end;
      true ->
         ok
   end,
   Input.
