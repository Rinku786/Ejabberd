%% name of module must match file name
-module(mod_confirm_delivery).

-author("Rinku Pandit- rinkuinagra@gmail.com").

%% Every ejabberd module implements the gen_mod behavior
%% The gen_mod behavior requires two functions: start/2 and stop/1
-behaviour(gen_mod).

%% public methods for this module
-export([start/2, stop/1, send_packet/3, receive_packet/4, get_session/7, set_offline_message/7, offlinemessageidstore_hook/3]).

%% included for writing to ejabberd log file
-include("ejabberd.hrl").
-include("logger.hrl").
-ifdef(LAGER).
-compile([{parse_transform, lager_transform}]).
-endif.
%%-define(INFO_MSG(Format, Args),
%%	lager:info(Format, Args)).
-define (Rtype, "received").
-define (Ctype, "chat").
-record(session, {sid, usr, us, priority, info}).
-record(offline_msg, {us, timestamp, expire, from, to, packet}).
-record(confirm_delivery, {messageid, timerref}).
-record(offline_message_id, {messageid, mestype}).
start(_Host, _Opt) -> 

        ?INFO_MSG("mod_confirm_delivery loading", []),
        mnesia:create_table(confirm_delivery, 
            [{attributes, record_info(fields, confirm_delivery)}]),
        mnesia:clear_table(confirm_delivery),
        ?INFO_MSG("created timer ref table", []),
	mnesia:create_table(offline_message_id, 
            [{attributes, record_info(fields, offline_message_id)}]),
        mnesia:clear_table(offline_message_id),
	ejabberd_hooks:add(offline_message_hook, _Host, ?MODULE, offlinemessageidstore_hook, 1),
        ?INFO_MSG("start user_send_packet hook", []),
        ejabberd_hooks:add(user_send_packet, _Host, ?MODULE, send_packet, 50),   
        ?INFO_MSG("start user_receive_packet hook", []),
        ejabberd_hooks:add(user_receive_packet, _Host, ?MODULE, receive_packet, 50),  
        ?INFO_MSG("after start user_receive_packet hook", []). 

stop(_Host) -> 
        ?INFO_MSG("stopping mod_confirm_delivery", []),
	ejabberd_hooks:delete(offline_message_hook, _Host, ?MODULE, offlinemessageidstore_hook, 1),
        ejabberd_hooks:delete(user_send_packet, _Host, ?MODULE, send_packet, 50),
        ejabberd_hooks:delete(user_receive_packet, _Host, ?MODULE, receive_packet, 50). 


offlinemessageidstore_hook(From, To, Packet) ->
	case offlinemessageidstore(From, To, Packet) of
	true ->
 		stop;
	_ ->
		ok
	end.



offlinemessageidstore(From, To, Packet) ->
	Type = xml:get_tag_attr_s("type", Packet),
	?INFO_MSG("offlinemessageidstore TYPE ~p", [Type]),
	Received = xml:get_subtag(Packet, "received"),
	if Received =/= false andalso Received =/= [] ->
		MessageId = xml:get_tag_attr_s("id", Received),
		delete_confirm_delivery(MessageId, ?Rtype);
		
	Type == "chat" orelse Type == "groupchat" ->
		MessageId = xml:get_tag_attr_s("id", Packet),
		delete_confirm_delivery(MessageId, ?Ctype);
	true ->
		MessageId = []
	end,
	?INFO_MSG("offlinemessageidstore before Case MesID ~p Received ~p ", [MessageId, Received]), 
		case mod_offline:check_event_chatstates(From, To, Packet) of
		true ->
			?INFO_MSG("offlinemessageidstore in Case ", []),
			 
			?INFO_MSG("offlinemessageidstore in Case after Received MesID ~p Type ~p ", [MessageId, Type]),
			if MessageId =/= [] ->
				if Type =/= [] ->
					Record = mnesia:dirty_read(offline_message_id, {MessageId, ?Ctype});
				true ->
					Record = mnesia:dirty_read(offline_message_id, {MessageId, ?Rtype})
				end;
			true ->
				Record = []
			end, 
			?INFO_MSG("offlinemessageidstore Record ~p Append ~p", [Record, mesValue]),
			if Record == [] ->
				?INFO_MSG("offlinemessageidstore MessageId ~p ", [MessageId]),
				F = fun() ->
					if Type =/= [] ->
						send_push(From, To, Packet),
						mnesia:write(#offline_message_id{messageid={MessageId, ?Ctype}, mestype=now()});
					true ->
						mnesia:write(#offline_message_id{messageid={MessageId, ?Rtype}, mestype=now()})					end
				end,

				mnesia:transaction(F),   
				?INFO_MSG("offlinemessageidstore After tranc Type ~p MessageId ~p ", [Type,MessageId]),
				false;

			true ->
				true
			end; 
		_ ->
			false
		end.



send_push(From, To, Packet) ->
 ?INFO_MSG("send_push STARTING.......",[]),
 MesBody = xml:get_path_s(Packet, [{elem, "body"}, cdata]),
 MesId = xml:get_tag_attr_s("id", Packet),
 MesTo = element(2, To),
 MesFrom = LUser = element(2, From),
 Bin2 = base64:encode(MesBody),
 Bin3 = re:replace(binary_to_list(Bin2), "\\+", "-", [global, {return,list}]),
 re:replace(Bin3, "/", "_", [global, {return,list}]),
 ?INFO_MSG("send_push Notification From: ~p To: ~p MsgID: ~p Message: ~p~n",[MesFrom, MesTo, MesId, Bin3]),
 Str = "php -f /var/www/html/freecell/erlang_push.php " ++ MesFrom ++ " " ++ MesTo ++ " " ++ MesId ++ " " ++ Bin3,
 Flag = os:cmd(Str),
 ?INFO_MSG("send_push STOP With code => ~p.",[Flag]).


send_packet(From, To, Packet) ->    
    ?INFO_MSG("send_packet FromJID ~p ToJID ~p Packet ~p~n",[From, To, Packet]),

    Type = xml:get_tag_attr_s("type", Packet),
    ?INFO_MSG("Message Type ~p~n",[Type]),

    Body = xml:get_path_s(Packet, [{elem, "body"}, cdata]), 
    ?INFO_MSG("Message Body ~p~n",[Body]),

    LUser = element(2, To),
    ?INFO_MSG("send_packet LUser ~p~n",[LUser]), 

    LServer = element(3, To), 
    ?INFO_MSG("send_packet LServer ~p~n",[LServer]), 

    Sessions = mnesia:dirty_index_read(session, {LUser, LServer}, #session.us),
    ?INFO_MSG("Session: ~p~n",[Sessions]),
	
    ReceivedConfirmation = xml:get_subtag(Packet, "receivedconfirmation"),

    Received = xml:get_subtag(Packet, "received"),
 
    ?INFO_MSG("receive_confirmation_packet Received Tag ~p~n",[ReceivedConfirmation]),
    if ReceivedConfirmation =/= false andalso ReceivedConfirmation =/= [] ->
        	MessageId = xml:get_tag_attr_s("id", ReceivedConfirmation);
        Received =/= false andalso Received =/= [] ->
		MessageId = xml:get_tag_attr_s("id", Received);	
    	true ->
        	MessageId = xml:get_tag_attr_s("id", Packet)
    	end, 

	
 	if ReceivedConfirmation =/= false andalso ReceivedConfirmation =/= [] andalso MessageId =/= [] ->   
		 ?INFO_MSG("Message_trace ReceivedConfirmation MessageId ~p Send_packet~n",[MessageId]),
         	Record = mnesia:dirty_read(confirm_delivery, {MessageId, ?Rtype}),
		?INFO_MSG("receive_packet Record: ~p~n",[Record]),
	    	if Record =/= [] ->
		[R] = Record,
		?INFO_MSG("receive_packet Record Elements ~p~n",[R]), 
		Ref = element(3, R),
		?INFO_MSG("receive_packet Cancel Timer ~p~n",[Ref]), 
		timer:cancel(Ref),
		mnesia:dirty_delete(confirm_delivery, {MessageId, ?Rtype}),
		?INFO_MSG("confirm_delivery clean up",[]);     
	        true ->
		ok
	    	end;
	  Received =/= false andalso Received =/= [] andalso MessageId =/= [] ->  
		 ?INFO_MSG("Message_trace Received MessageId ~p Send_packet~n",[MessageId]),
		Record = mnesia:dirty_read(confirm_delivery, {MessageId, ?Ctype}),
		?INFO_MSG("receive_packet Record: ~p~n",[Record]),
	    	if Record =/= [] ->
		[R] = Record,
		?INFO_MSG("receive_packet Record Elements ~p~n",[R]), 
		Ref = element(3, R),
		?INFO_MSG("receive_packet Cancel Timer ~p~n",[Ref]), 
		timer:cancel(Ref),
		mnesia:dirty_delete(confirm_delivery, {MessageId, ?Ctype}),
		?INFO_MSG("confirm_delivery clean up",[]);     
	        true ->
		ok
	    	end; 
         	
true ->             
        ok
    end.   

delete_offline_msgid(MessageId, Type) ->
?INFO_MSG("delete_offline_msgid: MesID ~p Type ~p",[MessageId, Type]),
if MessageId =/= [] ->
	mnesia:dirty_delete(offline_message_id, {MessageId, Type});
true ->
	ok
end.


delete_confirm_delivery(MessageId, Type) ->
?INFO_MSG("delete_offline_msgid: MesID ~p Type ~p",[MessageId, Type]),
if MessageId =/= [] ->
	mnesia:dirty_delete(confirm_delivery, {MessageId, Type});
true ->
	ok
end.


receive_packet(_JID, From, To, Packet) ->
    ?INFO_MSG("receive_packet JID: p From: p To: p Packet: p~n",[_JID, From, To, Packet]),
    Type = xml:get_tag_attr_s("type", Packet),
    ?INFO_MSG("Message Type ~p~n",[Type]),

    Body = xml:get_path_s(Packet, [{elem, "body"}, cdata]), 
    ?INFO_MSG("Message Body ~p~n",[Body]),

    LUser = element(2, To),
    ?INFO_MSG("send_packet LUser ~p~n",[LUser]), 

    LServer = element(3, To), 
    ?INFO_MSG("send_packet LServer ~p~n",[LServer]), 
 
    Received = xml:get_subtag(Packet, "received"),
    
    if Received =/= false andalso Received =/= [] ->
  MessageId = xml:get_tag_attr_s("id", Received), 
   ?INFO_MSG("message_trace Received MessageId ~p receive_packet",[MessageId]),
  Record = mnesia:dirty_read(confirm_delivery, {MessageId, ?Rtype}),
  if Record == [] ->
   OfflineRecord = mnesia:dirty_read(offline_message_id, {MessageId, ?Rtype}),
   if OfflineRecord =/= [] ->
		[R] = OfflineRecord,
		?INFO_MSG("receive_packet Record Elements ~p~n",[R]), 
		Currenttime = element(3, R);
   true ->
	Currenttime = now()
   end,
		
   delete_offline_msgid(MessageId , ?Rtype),
                %% set timer and enter in confirm_delivery
                {ok, Ref} = timer:apply_after(10000, mod_confirm_delivery, get_session, [LUser, LServer, From, To, Packet, ?Rtype, Currenttime]),

                ?INFO_MSG("Saving To p Ref p~n",[MessageId, Ref]),

          F = fun() ->
             mnesia:write(#confirm_delivery{messageid={MessageId, ?Rtype}, timerref=Ref})
          end,

           mnesia:transaction(F);

  true->
   delete_confirm_delivery(MessageId, ?Rtype)
  end;

    true ->
         MessageId = xml:get_tag_attr_s("id", Packet),
                if (Type=:= "chat" andalso Body =/= []) ->
   ?INFO_MSG("message_trace chat MessageId ~p receive_packet",[MessageId]),
   Record = mnesia:dirty_read(confirm_delivery, {MessageId, ?Ctype}),
   if Record == [] ->
	OfflineRecord = mnesia:dirty_read(offline_message_id, {MessageId, ?Ctype}),
  	 if OfflineRecord =/= [] ->
		[R] = OfflineRecord,
		?INFO_MSG("receive_packet Record Elements ~p~n",[R]), 
		Currenttime = element(3, R);
 	  true ->
		Currenttime = now()
	 end,
       delete_offline_msgid(MessageId , ?Ctype),
                    %% set timer and enter in confirm_delivery
                    {ok, Ref} = timer:apply_after(10000, mod_confirm_delivery, get_session, [LUser, LServer, From, To, Packet, ?Ctype, Currenttime]),

                 ?INFO_MSG("Saving To p Ref p~n",[MessageId, Ref]),

           F = fun() ->
              mnesia:write(#confirm_delivery{messageid={MessageId, ?Ctype}, timerref=Ref})
            end,

             mnesia:transaction(F);
       true->
       delete_confirm_delivery(MessageId, ?Ctype)
       end;
  true->
    ok
  end
  
    end.


get_session(User, Server, From, To, Packet, Type, Currenttime) ->  

?INFO_MSG("get_session User: ~p Server: ~p From: ~p To ~p Packet ~p ~n",[User, Server, From, To, Packet]),   


    set_offline_message(User, Server, From, To, Packet, Type, Currenttime),
    ?INFO_MSG("Set offline message...",[]),

    ejabberd_router:route(From, To, Packet),
    ?INFO_MSG("Resend message Currenttime ~p...",[Currenttime]).

    




set_offline_message(User, Server, From, To, Packet, _Type, TimeStamp) ->
	%%{MegaSecs, Secs, MicroSecs} = now(),
	%%Secs1 = Secs-10,
	%%TimeStamp = {MegaSecs, Secs1, MicroSecs},
       ?INFO_MSG("set_offline_message User: ~p Server: ~p From: ~p To ~p Packet ~p~n",[User, Server, From, To, Packet]),    

	Type = xml:get_tag_attr_s("type", Packet),
	?INFO_MSG("offlinesecondmessageidstore TYPE ~p argv ~p", [Type, argv]),
	Received = xml:get_subtag(Packet, "received"),
	if Received =/= false andalso Received =/= [] ->
		MessageId = xml:get_tag_attr_s("id", Received);
		
	Type == "chat" orelse Type == "groupchat" ->
		MessageId = xml:get_tag_attr_s("id", Packet);
	true ->
		MessageId = []
	end,
	?INFO_MSG("offlinemessageidstore before Case MesID ~p Received ~p ", [MessageId, Received]), 
		case mod_offline:check_event_chatstates(From, To, Packet) of
		true ->
			?INFO_MSG("offlinemessageidstore in Case ", []),
			 
			?INFO_MSG("offlinemessageidstore in Case after Received MesID ~p Type ~p ", [MessageId, Type]),
			if MessageId =/= [] ->
				if Type =/= [] ->
					Record = mnesia:dirty_read(offline_message_id, {MessageId, ?Ctype});
				true ->
					Record = mnesia:dirty_read(offline_message_id, {MessageId, ?Rtype})
				end;
			true ->
				Record = []
			end, 
			?INFO_MSG("offlinemessageidstore Record ~p Append ~p", [Record, mesValue]),
			if Record == [] ->
					
				?INFO_MSG("offlinemessageidstore MessageId ~p ", [MessageId]),
				F = fun() ->
					if Type =/= [] ->
						send_push(From, To, Packet),
						mnesia:write(#offline_message_id{messageid={MessageId, ?Ctype}, mestype=TimeStamp});
					true ->
						mnesia:write(#offline_message_id{messageid={MessageId, ?Rtype}, mestype=TimeStamp})					end
				end,

				mnesia:transaction(F),   
				?INFO_MSG("offlinemessageidstore After tranc Type ~p MessageId ~p ", [Type,MessageId]),
					J = fun() ->
        mnesia:write(#offline_msg{us = {User, Server}, timestamp = TimeStamp, expire = "never", from = From, to = To, packet = Packet})
    end,

    mnesia:transaction(J);

			true ->
				true
			end; 
		_ ->
				F = fun() ->
        mnesia:write(#offline_msg{us = {User, Server}, timestamp = TimeStamp, expire = "never", from = From, to = To, packet = Packet})
    end,

    mnesia:transaction(F)
		end.



