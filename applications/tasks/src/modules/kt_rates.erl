%%%-------------------------------------------------------------------
%%% @copyright (C) 2013-2017, 2600Hz
%%% @doc
%%%
%%% @end
%%% @contributors
%%%   Sergey Korobkov
%%%-------------------------------------------------------------------
-module(kt_rates).
%% behaviour: tasks_provider

-export([init/0
        ,help/1, help/2, help/3
        ,output_header/1
        ,cleanup/2
        ]).

%% Verifiers
-export([direction/1
        ]).

%% Appliers
-export([export/2
        ,import/3
        ,delete/3
        ]).

-include("tasks.hrl").
-include("modules/kt_rates.hrl").

-define(CATEGORY, "rates").
-define(ACTIONS, [<<"export">>
                 ,<<"import">>
                 ,<<"delete">>
                 ]).
-define(RATES_VIEW, <<"rates/lookup">>).
-define(BULK_LIMIT, 500).

%%%===================================================================
%%% API
%%%===================================================================

-spec init() -> 'ok'.
init() ->
    _ = tasks_bindings:bind(<<"tasks.help">>, ?MODULE, 'help'),
    _ = tasks_bindings:bind(<<"tasks."?CATEGORY".output_header">>, ?MODULE, 'output_header'),
    _ = tasks_bindings:bind(<<"tasks."?CATEGORY".direction">>, ?MODULE, 'direction'),
    _ = tasks_bindings:bind(<<"tasks."?CATEGORY".cleanup">>, ?MODULE, 'cleanup'),
    tasks_bindings:bind_actions(<<"tasks."?CATEGORY>>, ?MODULE, ?ACTIONS).

-spec output_header(ne_binary()) -> kz_csv:row().
output_header(<<"export">>) -> ?DOC_FIELDS.

-spec help(kz_json:object()) -> kz_json:object().
help(JObj) -> help(JObj, <<?CATEGORY>>).

-spec help(kz_json:object(), ne_binary()) -> kz_json:object().
help(JObj, <<?CATEGORY>>=Category) ->
    lists:foldl(fun(Action, J) -> help(J, Category, Action) end, JObj, ?ACTIONS).

-spec help(kz_json:object(), ne_binary(), ne_binary()) -> kz_json:object().
help(JObj, <<?CATEGORY>>=Category, Action) ->
    kz_json:set_value([Category, Action], kz_json:from_list(action(Action)), JObj).

-spec action(ne_binary()) -> kz_proplist().
action(<<"export">>) ->
    [{<<"description">>, <<"Export ratedeck">>}
    ,{<<"doc">>, <<"Export rates from the supplied ratedeck">>}
    ];

action(<<"import">>) ->
    %% prefix & cost are mandatory fields
    Mandatory = ?MANDATORY_FIELDS,
    Optional = ?DOC_FIELDS -- Mandatory,

    [{<<"description">>, <<"Bulk-import rates to a specified ratedeck">>}
    ,{<<"doc">>, <<"Creates rates from file">>}
    ,{<<"expected_content">>, <<"text/csv">>}
    ,{<<"mandatory">>, Mandatory}
    ,{<<"optional">>, Optional}
    ];

action(<<"delete">>) ->
    %% prefix is mandatory field
    Mandatory = [<<"prefix">>],
    Optional = ?DOC_FIELDS -- Mandatory,
    [{<<"description">>, <<"Bulk-remove rates">>}
    ,{<<"doc">>, <<"Delete rates from file">>}
    ,{<<"expected_content">>, <<"text/csv">>}
    ,{<<"mandatory">>, Mandatory}
    ,{<<"optional">>, Optional}
    ].

%%% Verifiers

-spec direction(ne_binary()) -> boolean().
direction(<<"inbound">>) -> 'true';
direction(<<"outbound">>) -> 'true';
direction(_) -> 'false'.

%%% Appliers

-spec export(kz_tasks:extra_args(), kz_tasks:iterator()) -> kz_tasks:iterator().
export(ExtraArgs, 'init') ->
    case is_allowed(ExtraArgs) of
        'true' ->
            State = [{'db', get_ratedeck_db(ExtraArgs)}
                    ,{'options', [{'limit', ?BULK_LIMIT + 1}
                                 ,'include_docs'
                                 ]
                     }
                    ],
            export(ExtraArgs, State);
        'false' ->
            lager:warning("rates exporting is forbidden for account ~s, auth account ~s"
                         ,[maps:get('account_id', ExtraArgs)
                          ,maps:get('auth_account_id', ExtraArgs)
                          ]
                         ),
            {<<"task execution is forbidden">>, 'stop'}
    end;
export(_ExtraArgs, 'stop') -> 'stop';
export(_ExtraArgs, State) ->
    Db = props:get_value('db', State),
    Options = props:get_value('options', State),
    Limit = props:get_value(['options', 'limit'], State),
    case kz_datamgr:get_results(Db, ?RATES_VIEW, Options) of
        {'ok', []} -> 'stop';
        {'ok', Results} when length(Results) >= Limit ->
            {Head, Last} = split_results(Results),
            Rows = [to_csv_row(R) || R <- Head],
            NewOptions = props:set_values([{'startkey', kz_json:get_value(<<"key">>, Last)}
                                          ,{'startkey_docid', kz_json:get_value(<<"id">>, Last)}
                                          ]
                                         ,Options
                                         ),
            NewState = props:set_value('options', NewOptions, State),
            {Rows, NewState};
        {'ok', Results} ->
            Rows = [to_csv_row(R) || R <- Results],
            {Rows, 'stop'}
    end.

-spec import(kz_tasks:extra_args(), dict:dict() | kz_tasks:iterator(), kz_tasks:args()) -> kz_tasks:iterator().
import(ExtraArgs, 'init', Args) ->
    case is_allowed(ExtraArgs) of
        'true' ->
            lager:info("import is allowed, continuing"),
            import(ExtraArgs, dict:new(), Args);
        'false' ->
            lager:warning("rates importing is forbidden for account ~s, auth account ~s"
                         ,[maps:get('account_id', ExtraArgs)
                          ,maps:get('auth_account_id', ExtraArgs)
                          ]
                         ),
            {<<"task execution is forbidden">>, 'stop'}
    end;
import(_ExtraArgs, Dict, Args) ->
    Rate = generate_row(Args),
    Db = kzd_ratedeck:format_ratedeck_db(kzd_rate:ratedeck(Rate, ?KZ_RATES_DB)),

    BulkLimit = kz_datamgr:max_bulk_insert(),

    case dict:find(Db, Dict) of
        'error' ->
            lager:debug("adding prefix ~s to ~s", [kzd_rate:prefix(Rate), Db]),
            {[], dict:store(Db, {1, [Rate]}, Dict)};
        {'ok', {BulkLimit, Rates}} ->
            lager:info("saving ~b rates to ~s", [BulkLimit, Db]),
            kz_datamgr:suppress_change_notice(),
            save_rates(Db, [Rate | Rates]),
            kz_datamgr:enable_change_notice(),
            {[], dict:store(Db, {0, []}, Dict)};
        {'ok', {Size, Rates}} ->
            {[], dict:store(Db, {Size+1, [Rate | Rates]}, Dict)}
    end.

-spec delete(kz_tasks:extra_args(), kz_tasks:iterator(), kz_tasks:args()) -> kz_tasks:iterator().
delete(ExtraArgs, 'init', Args) ->
    kz_datamgr:suppress_change_notice(),
    case is_allowed(ExtraArgs) of
        'true' ->
            State = [{'db', get_ratedeck_db(ExtraArgs)}
                    ,{'limit', ?BULK_LIMIT}
                    ,{'count', 0}
                    ,{'keys', []}
                    ,{'dict', dict:new()}
                    ],
            delete(ExtraArgs, State, Args);
        'false' ->
            lager:warning("rates deleting is forbidden for account ~s, auth account ~s"
                         ,[maps:get('account_id', ExtraArgs)
                          ,maps:get('auth_account_id', ExtraArgs)
                          ]
                         ),
            {<<"task execution is forbidden">>, 'stop'}
    end;
delete(_ExtraArgs, State, Args) ->
    Rate = kzd_rate:from_map(Args),

    Limit = props:get_value('limit', State),
    Count = props:get_value('count', State) + 1,
    P = kz_term:to_integer(kzd_rate:prefix(Rate)),

    %% override account-ID from task props
    Dict = dict:append(P, Rate, props:get_value('dict', State)),
    Keys = [P | props:get_value('keys', State)],
    case Count rem Limit of
        0 ->
            Db = props:get_value('db', State),
            delete_rates(Db, Keys, Dict),
            {[], props:set_values([{'count', Count}
                                  ,{'keys', []}
                                  ,{'dict', dict:new()}
                                  ]
                                 ,State
                                 )
            };
        _Rem ->
            {[], props:set_values([{'count', Count}
                                  ,{'keys', Keys}
                                  ,{'dict', Dict}
                                  ]
                                 ,State
                                 )
            }
    end.

-spec cleanup(ne_binary(), any()) -> any().
cleanup(<<"import">>, Dict) ->
    _ = dict:map(fun import_rates_into_ratedeck/2, Dict);
cleanup(<<"delete">>, State) ->
    Db = props:get_value('db', State),
    Keys = props:get_value('keys', State),
    Dict = props:get_value('dict', State),
    delete_rates(Db, Keys, Dict),
    kz_datamgr:enable_change_notice(),
    kzs_publish:publish_db(Db, <<"edited">>).

-spec import_rates_into_ratedeck(ne_binary(), {non_neg_integer(), kz_json:objects()}) -> 'ok'.
import_rates_into_ratedeck(Ratedeck, {0, []}) ->
    RatedeckDb = kzd_ratedeck:format_ratedeck_db(Ratedeck),
    kz_datamgr:enable_change_notice(),
    kzs_publish:publish_db(RatedeckDb, <<"edited">>);
import_rates_into_ratedeck(Ratedeck, {_, Rates}) ->
    kz_datamgr:suppress_change_notice(),
    save_rates(kzd_ratedeck:format_ratedeck_db(Ratedeck), Rates),
    import_rates_into_ratedeck(Ratedeck, {0, []}).

%%%===================================================================
%%% Internal functions
%%%===================================================================

-spec split_results(kz_json:objects()) -> {kz_json:objects(), kz_json:object()}.
split_results([_|_] = JObjs) ->
    {Head, [Last]} = lists:split(length(JObjs)-1, JObjs),
    %% !!!
    %% workaround untill https://github.com/benoitc/couchbeam/pull/160
    %% !!!
    case kz_json:get_value(<<"key">>, lists:last(Head)) =:= kz_json:get_value(<<"key">>, Last) of
        'true' -> split_results(Head);
        'false' -> {Head, Last}
    end.

-spec is_allowed(kz_tasks:extra_args()) -> boolean().
is_allowed(ExtraArgs) ->
    AuthAccountId = maps:get('auth_account_id', ExtraArgs),
    AccountId = maps:get('account_id', ExtraArgs),
    {'ok', AccountDoc} = kz_account:fetch(AccountId),
    {'ok', AuthAccountDoc} = kz_account:fetch(AuthAccountId),
    kz_util:is_in_account_hierarchy(AuthAccountId, AccountId, 'true')
    %% Serve request for reseller rates
        andalso kz_account:is_reseller(AccountDoc)
    %% or serve requests from SuperAdmin
        orelse kz_account:is_superduper_admin(AuthAccountDoc).

-spec get_ratedeck_db(kz_tasks:extra_args()) -> ne_binary().
get_ratedeck_db(_ExtraArgs) ->
    %% TODO: per account DB?
    ?KZ_RATES_DB.

-spec to_csv_row(kz_json:object()) -> kz_csv:row().
to_csv_row(Row) ->
    Doc = kz_json:get_json_value(<<"doc">>, Row),
    [kz_json:get_binary_value(Key, Doc) || Key <- ?DOC_FIELDS].

-spec generate_row(kz_tasks:args()) -> kzd_rate:doc().
generate_row(Args) ->
    RateJObj = kzd_rate:from_map(Args),
    Prefix = kzd_rate:prefix(RateJObj),

    Update = props:filter_undefined(
               [{fun kzd_rate:set_name/2, maybe_generate_name(RateJObj)}
               ,{fun kzd_rate:set_weight/2, maybe_generate_weight(RateJObj)}
               ,{fun kzd_rate:set_routes/2, [<<"^\\+?", Prefix/binary, ".+$">>]}
               ]),
    kz_json:set_values(Update, RateJObj).

-spec save_rates(ne_binary(), kzd_rate:docs()) -> 'ok'.
save_rates(Db, Rates) ->
    case kz_datamgr:save_docs(Db, Rates) of
        {'ok', _Result} ->
            refresh_selectors_index(Db);
        {'error', 'not_found'} ->
            lager:debug("failed to find database ~s", [Db]),
            init_db(Db),
            save_rates(Db, Rates);
        %% Workaround, need to fix!
        %% We assume that is everything ok and try to refresh index
        {'error', 'timeout'} -> refresh_selectors_index(Db)
    end.

-spec delete_rates(ne_binary(), list(), dict:dict()) -> 'ok'.
delete_rates(Db, Keys, Dict) ->
    Options = [{'keys', Keys}
              ,'include_docs'
              ],
    case kz_datamgr:get_results(Db, ?RATES_VIEW, Options) of
        {'ok', []} -> 'ok';
        {'ok', Results} ->
            Docs = lists:filtermap(fun(R) -> maybe_delete_rate(R, Dict) end, Results),
            do_delete_rates(Db, Docs)
    end.

-spec do_delete_rates(ne_binary(), kz_json:objects()) -> 'ok'.
do_delete_rates(_Db, []) -> 'ok';
do_delete_rates(Db, Docs) ->
    {Head, Rest} = case length(Docs) > ?BULK_LIMIT
                       andalso lists:split(?BULK_LIMIT, Docs)
                   of
                       'false' -> {Docs, []};
                       {H, T} -> {H, T}
                   end,
    case kz_datamgr:del_docs(Db, Head) of
        {'ok', _} -> refresh_selectors_index(Db);
        %% Workaround, need to fix!
        %% We assume that is everything ok and try to refresh index
        {'error', 'timeout'} -> refresh_selectors_index(Db)
    end,
    do_delete_rates(Db, Rest).

-spec refresh_selectors_index(ne_binary()) -> 'ok'.
refresh_selectors_index(Db) ->
    {'ok', _} = kz_datamgr:all_docs(Db, [{'limit', 1}]),
    {'ok', _} = kz_datamgr:get_results(Db, <<"rates/lookup">>, [{'limit', 1}]),
    'ok'.

-spec init_db(ne_binary()) -> 'ok'.
init_db(Db) ->
    _Created = kz_datamgr:db_create(Db),
    lager:debug("created ~s: ~s", [Db, _Created]),
    {'ok', _} = kz_datamgr:revise_doc_from_file(Db, 'crossbar', "views/rates.json"),
    lager:info("initialized new ratedeck ~s", [Db]).

-spec maybe_delete_rate(kz_json:object(), dict:dict()) -> kz_json:object() | 'false'.
maybe_delete_rate(JObj, Dict) ->
    Prefix = kz_term:to_integer(kz_json:get_value(<<"key">>, JObj)),
    Doc = kz_json:get_value(<<"doc">>, JObj),
    ReqRates = dict:fetch(Prefix, Dict),
    %% Delete docs only if its match with all defined fields in CSV row
    case lists:any(fun(ReqRate) ->
                           lists:all(fun({ReqKey, ReqValue}) ->
                                             kz_json:get_value(ReqKey, Doc) =:= ReqValue
                                     end
                                    ,ReqRate
                                    )
                   end
                  ,ReqRates
                  )
    of
        'true' -> {'true', Doc};
        'false' -> 'false'
    end.

-spec maybe_default(kz_transaction:units(), kz_transaction:units()) -> kz_transaction:units().
maybe_default(0, Default) -> Default;
maybe_default(Value, _Default) -> Value.

-spec maybe_generate_name(kzd_rate:doc()) -> ne_binary().
-spec maybe_generate_name(kzd_rate:doc(), api_ne_binary()) -> ne_binary().
-spec generate_name(ne_binary(), api_ne_binary(), ne_binaries()) -> ne_binary().
maybe_generate_name(RateJObj) ->
    maybe_generate_name(RateJObj, kzd_rate:name(RateJObj)).

maybe_generate_name(RateJObj, 'undefined') ->
    generate_name(kzd_rate:prefix(RateJObj)
                 ,kzd_rate:iso_country_code(RateJObj)
                 ,kzd_rate:direction(RateJObj, [])
                 );
maybe_generate_name(_RateJObj, Name) -> Name.

generate_name(Prefix, 'undefined', []) when is_binary(Prefix) ->
    Prefix;
generate_name(Prefix, ISO, []) ->
    <<ISO/binary, "_", Prefix/binary>>;
generate_name(Prefix, 'undefined', Directions) ->
    Direction = kz_binary:join(Directions, <<"_">>),
    <<Direction/binary, "_", Prefix/binary>>;
generate_name(Prefix, ISO, Directions) ->
    Direction = kz_binary:join(Directions, <<"_">>),
    <<Direction/binary, "_", ISO/binary, "_", Prefix/binary>>.

-spec maybe_generate_weight(kzd_rate:doc()) -> integer().
-spec maybe_generate_weight(kzd_rate:doc(), api_integer()) -> integer().
maybe_generate_weight(RateJObj) ->
    maybe_generate_weight(RateJObj, kzd_rate:weight(RateJObj, 'undefined')).

maybe_generate_weight(RateJObj, 'undefined') ->
    generate_weight(kzd_rate:prefix(RateJObj)
                   ,kzd_rate:rate_cost(RateJObj)
                   ,kzd_rate:private_cost(RateJObj)
                   );
maybe_generate_weight(_RateJObj, Weight) -> kzd_rate:constrain_weight(Weight).

-spec generate_weight(ne_binary(), kz_transaction:units(), kz_transaction:units()) ->
                             kzd_rate:weight_range().
generate_weight(?NE_BINARY = Prefix, UnitCost, UnitIntCost) ->
    UnitCostToUse = maybe_default(UnitIntCost, UnitCost),
    CostToUse = wht_util:units_to_dollars(UnitCostToUse),

    Weight = (byte_size(Prefix) * 10) - trunc(CostToUse * 100),
    kzd_rate:constrain_weight(Weight).
