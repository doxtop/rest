-module(rest_cowboy).
-author('Dmitry Bushmelev').
-record(st, {resource_module = undefined :: atom(), resource_id = undefined :: binary()}).
-export([init/2, rest_init/2, resource_exists/2, allowed_methods/2, content_types_provided/2,
         to_html/2, to_json/2, content_types_accepted/2, delete_resource/2,
         handle_urlencoded_data/2, handle_json_data/2]).

init(Req,Opt) -> {cowboy_rest, Req, Opt}.

-ifndef(REST_JSON).
-define(REST_JSON, (application:get_env(rest,json,jsone))).
-endif.

c(X) -> list_to_atom(binary_to_list(X)).

rest_init(Req, _Opts) ->
    {Resource, Req1} = cowboy_req:binding(resource, Req),
    Module = case rest_module(Resource) of {ok, M} -> M; _ -> undefined end,
    {Id, Req2} = cowboy_req:binding(id, Req1),
    {Origin, Req3} = cowboy_req:header(<<"Origin">>, Req2, <<"*">>),
    Req4 = cowboy_req:set_resp_header(<<"Access-Control-Allow-Origin">>, Origin, Req3),
    {ok, Req4, #st{resource_module = Module, resource_id = Id}}.

resource_exists(#{bindings := #{resource := M, id:=Id}} = Req, S) -> {(c(M)):exists(Id), Req, S};
resource_exists(#{bindings := #{resource := M}} = Req, State)     -> {(c(M)):exists(all),Req, State};
resource_exists(#{bindings := #{id := _}} = Req, State)           -> {true, Req, State}.

allowed_methods(#{bindings := #{resource := _}} = Req, State) -> {[<<"GET">>, <<"POST">>], Req, State};
allowed_methods(#{bindings := #{resource :=_,id := _}} = Req, State)-> {[<<"GET">>, <<"PUT">>, <<"DELETE">>], Req, State}.

content_types_provided(#{bindings := #{resource := M}} = Req, State) ->
    {case erlang:function_exported(c(M), to_html, 1) of
         true  -> [{<<"text/html">>, to_html}, {<<"application/json">>, to_json}];
         false -> [{<<"application/json">>, to_json}]
      end,
     Req, State}.

to_html(#{bindings := #{resource := Module, id:=Id}} = Req, State) ->
    M = c(Module),
    Body = case Id of
               undefined -> [M:to_html(Resource) || Resource <- M:get()];
               _ -> M:to_html(M:get(Id)) end,
    Html = case erlang:function_exported(M, html_layout, 2) of
               true  -> M:html_layout(Req, Body);
               false -> default_html_layout(Body) end,
    {Html, Req, State}.

default_html_layout(Body) -> [<<"<html><body>">>, Body, <<"</body></html>">>].

to_json(#{bindings := #{resource := Module, id := Id}} = Req, State) ->
    M = c(Module),
    Struct = case Id of
                 undefined -> #{Module => [M:to_json(R) || R<- M:get()]};
                 _         -> M:to_json(M:get(Id)) end,
    {iolist_to_binary(?REST_JSON:encode(Struct)), Req, State};
to_json(#{bindings := #{resource := _}} =Req, State) ->
  #{bindings := B} = Req, B1 = B#{id => undefined},
  to_json(Req#{bindings:=B1},State).


content_types_accepted(Req, State) -> {[{<<"application/x-www-form-urlencoded">>, handle_urlencoded_data},
                                        {<<"application/json">>, handle_json_data}], Req, State}.

handle_urlencoded_data(#{bindings:=#{resource:=M, id:=Id}} = Req, State) ->
    {ok, Data, Req2} = cowboy_req:body_qs(Req),
    {handle_data(c(M), Id, Data), Req2, State}.

handle_json_data(#{bindings:=#{resource:=M, id:=Id}} = Req, State) ->
    case cowboy_req:read_body(Req) of
        {ok, Binary, Req2} ->
            case ?REST_JSON:try_decode(Binary) of
                {ok, Value, _} ->
                    case handle_data(c(M), Id, Value) of
                        Handled when is_boolean(Handled) -> {Handled, Req2, State};
                        Body -> {true, cowboy_req:set_resp_body(iolist_to_binary(Body), Req2), State} end;

                {error, _} -> {false,Req,State} end; % bad request is not a server fault
        {more,_,_}  -> {false, Req, State}; %> 1Mb text entry, really?
        {error,_}   -> {false, Req, State} end;
handle_json_data(#{bindings:=#{resource:=_}}=Req, State) ->
  #{bindings :=B} = Req, B1 = B#{id => undefined},
  handle_json_data(Req#{bindings:=B1},State).

-spec handle_data(_,_,_) -> boolean() | iodata().
handle_data(Mod, Id, {struct, Data}) -> handle_data(Mod, Id, Data);
handle_data(Mod, Id, {Data}) ->
    case erlang:function_exported(Mod, unit, 0) of 
        true -> handle_data(Mod, Id, Mod:from_json(Data, Mod:unit()));
        false -> false end;
handle_data(Mod, Id, Data) ->
    Valid = case erlang:function_exported(Mod, validate, 2) of
                true  -> Mod:validate(Id, Data);
                false -> default_validate(Mod, Id, Data) end,
    case {Valid, Id} of
        {false, _}         -> false;
        {true,  undefined} -> Mod:post(Data);
        {true,  _}         -> case erlang:function_exported(Mod, put, 2) of
                                  true  -> Mod:put(Id, Data);
                                  false -> default_put(Mod, Id, Data) end
    end.

default_put(Mod, Id, Data) ->
    NewRes = Mod:from_json(Data, Mod:get(Id)),
    NewId = proplists:get_value(id, Mod:to_json(NewRes)),
    case Id =/= NewId of
        true  -> Mod:delete(Id);
        false -> true end,
    Mod:post(NewRes).

default_validate(Mod, Id, Data) when is_tuple(Data) -> true;
default_validate(Mod, Id, Data) ->
    Allowed = case erlang:function_exported(Mod, keys_allowed, 1) of
                  true  -> Mod:keys_allowed(proplists:get_keys(Data));
                  false -> true end,
    validate_match(Mod, Id, Allowed, proplists:get_value(<<"id">>, Data)).

validate_match(_Mod, undefined, true, undefined) -> false;
validate_match(_Mod, undefined, true, <<"">>)    -> false;
validate_match( Mod, undefined, true, NewId)     -> not Mod:exists(NewId);
validate_match(_Mod,       _Id, true, undefined) -> true;
validate_match(_Mod,        Id, true, Id)        -> true;
validate_match( Mod,       _Id, true, NewId)     -> not Mod:exists(NewId);
validate_match(   _,         _,    _, _)         -> false.

delete_resource(#{bindings := #{resource := M, id := Id}}=Req,  State) -> 
  {(c(M)):delete(Id), Req, State}.

rest_module(Module) when is_binary(Module) -> rest_module(binary_to_list(Module));
rest_module(Module) ->
    try M = list_to_existing_atom(Module),
        Info = proplists:get_value(attributes, M:module_info()),
        true = lists:member(rest, proplists:get_value(behaviour, Info)),
        {ok, M}
    catch error:Error -> {error, Error} end.
