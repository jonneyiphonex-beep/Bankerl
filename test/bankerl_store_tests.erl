-module(bankerl_store_tests).
-include_lib("eunit/include/eunit.hrl").

registration_and_session_test() ->
    with_store(fun() ->
        {ok, Token, Dashboard} = bankerl_store:register("Amina Noor", "amina@example.org",
                                                        "correct-horse-battery"),
        CustomerNumber = binary_to_list(maps:get(customer_number,
                              maps:get(user, Dashboard))),
        ?assertEqual(10, length(CustomerNumber)),
        ?assertEqual(0, maps:get(total_balance_cents, Dashboard)),
        ?assertMatch({ok, _}, bankerl_store:dashboard(Token)),
        ?assertMatch({ok, _, _}, bankerl_store:login(CustomerNumber,
                                 "correct-horse-battery")),
        ?assertEqual({error, invalid_credentials},
                 bankerl_store:login("amina@example.org", "correct-horse-battery")),
        ?assertEqual({error, email_already_registered},
                     bankerl_store:register("Amina Noor", "AMINA@example.org",
                                            "another-correct-password")),
        ok = bankerl_store:logout(Token),
        ?assertEqual({error, unauthorized}, bankerl_store:dashboard(Token))
    end).

transfer_and_no_overdraft_test() ->
    with_store(fun() ->
        {ok, SenderToken, _} = bankerl_store:register("Amina Noor", "amina@example.org",
                                                      "correct-horse-battery"),
        {ok, _RecipientToken, _} = bankerl_store:register("Yusuf Ali", "yusuf@example.org",
                                                          "another-correct-password"),
        {ok, _} = bankerl_store:deposit(SenderToken, 25000),
        ?assertEqual({error, insufficient_funds},
                     bankerl_store:withdraw(SenderToken, 25001)),
        {ok, SenderDashboard} = bankerl_store:transfer(SenderToken, "yusuf@example.org",
                                                       7000, "Rent share"),
        ?assertEqual(18000, maps:get(total_balance_cents, SenderDashboard)),
        ?assertMatch({error, cannot_transfer_to_self},
                     bankerl_store:transfer(SenderToken, "amina@example.org", 100, ""))
    end).

zakat_estimate_test() ->
    with_store(fun() ->
        {ok, Token, _} = bankerl_store:register("Amina Noor", "amina@example.org",
                                                "correct-horse-battery"),
        {ok, _} = bankerl_store:deposit(Token, 1000000),
        {ok, Estimate} = bankerl_store:calculate_zakat(Token, 500000),
        ?assertEqual(25000, maps:get(estimated_zakat_cents, Estimate)),
        ?assertEqual({error, invalid_nisab}, bankerl_store:calculate_zakat(Token, 0))
    end).

move_between_owned_accounts_test() ->
    with_store(fun() ->
        {ok, Token, _} = bankerl_store:register("Amina Noor", "amina@example.org",
                                                "correct-horse-battery"),
        {ok, _} = bankerl_store:deposit(Token, 20000),
        {ok, _} = bankerl_store:open_savings(Token),
        {ok, Dashboard} = bankerl_store:dashboard(Token),
        Current = hd([Account || Account <- maps:get(accounts, Dashboard),
                                  maps:get(type, Account) =:= current]),
        Savings = hd([Account || Account <- maps:get(accounts, Dashboard),
                                  maps:get(type, Account) =:= mudarabah]),
        CurrentId = binary_to_list(maps:get(id, Current)),
        SavingsId = binary_to_list(maps:get(id, Savings)),
        {ok, Moved} = bankerl_store:move_funds(Token, CurrentId, SavingsId, 12500),
        ?assertEqual(20000, maps:get(total_balance_cents, Moved)),
        ?assertEqual({error, insufficient_funds},
                    bankerl_store:move_funds(Token, CurrentId, SavingsId, 7501))
    end).

persistence_restart_test() ->
    File = temporary_file(),
    {ok, FirstPid} = bankerl_store:start_link(File),
    {ok, Token, InitialDashboard} = bankerl_store:register("Amina Noor", "amina@example.org",
                                                           "correct-horse-battery"),
    CustomerNumber = binary_to_list(maps:get(customer_number,
                                              maps:get(user, InitialDashboard))),
    {ok, _} = bankerl_store:deposit(Token, 4525),
    ok = gen_server:stop(FirstPid),
    {ok, SecondPid} = bankerl_store:start_link(File),
    try
        {ok, RestoredToken, _} = bankerl_store:login(CustomerNumber,
                                                    "correct-horse-battery"),
        {ok, Dashboard} = bankerl_store:dashboard(RestoredToken),
        ?assertEqual(4525, maps:get(total_balance_cents, Dashboard))
    after
        gen_server:stop(SecondPid),
        file:delete(File),
        file:delete(File ++ ".tmp")
    end.

with_store(Test) ->
    File = temporary_file(),
    {ok, Pid} = bankerl_store:start_link(File),
    try Test()
    after
        gen_server:stop(Pid),
        file:delete(File),
        file:delete(File ++ ".tmp")
    end.

temporary_file() ->
        filename:join("/tmp", "bankerl-test-" ++
            lists:flatten([io_lib:format("~2.16.0b", [Byte]) ||
                <<Byte>> <= crypto:strong_rand_bytes(8)]) ++ ".db").