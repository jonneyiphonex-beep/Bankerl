-module(bankerl_store).
-behaviour(gen_server).

-export([start_link/1, register/3, login/2, logout/1, dashboard/1,
         deposit/2, withdraw/2, transfer/4, open_savings/1,
         move_funds/4, calculate_zakat/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(PASSWORD_ROUNDS, 120000).
-define(SESSION_SECONDS, 86400).

start_link(DataFile) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, DataFile, []).

register(Name, Email, Password) ->
    gen_server:call(?MODULE, {register, Name, Email, Password}).

login(CustomerNumber, Password) ->
    gen_server:call(?MODULE, {login, CustomerNumber, Password}).

logout(Token) ->
    gen_server:call(?MODULE, {logout, Token}).

dashboard(Token) ->
    gen_server:call(?MODULE, {dashboard, Token}).

deposit(Token, Amount) ->
    gen_server:call(?MODULE, {deposit, Token, Amount}).

withdraw(Token, Amount) ->
    gen_server:call(?MODULE, {withdraw, Token, Amount}).

transfer(Token, Email, Amount, Note) ->
    gen_server:call(?MODULE, {transfer, Token, Email, Amount, Note}).

open_savings(Token) ->
    gen_server:call(?MODULE, {open_savings, Token}).

move_funds(Token, FromAccountId, ToAccountId, Amount) ->
    gen_server:call(?MODULE, {move_funds, Token, FromAccountId, ToAccountId, Amount}).

calculate_zakat(Token, NisabCents) ->
    gen_server:call(?MODULE, {calculate_zakat, Token, NisabCents}).

init(DataFile) ->
    process_flag(trap_exit, true),
    {StoredUsers, Accounts, Transactions} = load_data(DataFile),
    Users = assign_customer_numbers(StoredUsers),
    State = #{data_file => DataFile,
              users => Users,
              accounts => Accounts,
              transactions => Transactions,
              sessions => #{}},
    case Users =:= StoredUsers of
        true -> {ok, State};
        false ->
            case persist(State) of
                ok -> {ok, State};
                {error, Reason} -> {stop, {customer_number_migration_failed, Reason}}
            end
    end.

handle_call({register, Name0, Email0, Password}, _From, State) ->
    Name = string:trim(Name0),
    Email = string:lowercase(string:trim(Email0)),
    case validate_registration(Name, Email, Password) of
        ok -> create_user(Name, Email, Password, State);
        Error -> {reply, Error, State}
    end;
handle_call({login, CustomerNumber0, Password}, _From, State) ->
    CustomerNumber = string:trim(CustomerNumber0),
    case find_user_by_customer_number(CustomerNumber, maps:get(users, State)) of
        {ok, User} ->
            case password_matches(Password, User) of
                true ->
                    {Token, Sessions} = new_session(maps:get(id, User),
                                                    maps:get(sessions, State)),
                    NewState = State#{sessions => Sessions},
                    {reply, {ok, Token, dashboard_for(maps:get(id, User), NewState)},
                     NewState};
                false -> {reply, {error, invalid_credentials}, State}
            end;
        error -> {reply, {error, invalid_credentials}, State}
    end;
handle_call({logout, Token}, _From, State) ->
    {reply, ok, State#{sessions => maps:remove(Token, maps:get(sessions, State))}};
handle_call({dashboard, Token}, _From, State) ->
    with_user(Token, State,
      fun(UserId) -> {ok, dashboard_for(UserId, State)} end);
handle_call({deposit, Token, Amount}, _From, State) ->
    with_user(Token, State,
      fun(UserId) -> change_balance(UserId, Amount, deposit, State) end);
handle_call({withdraw, Token, Amount}, _From, State) ->
    with_user(Token, State,
      fun(UserId) -> change_balance(UserId, Amount, withdrawal, State) end);
handle_call({transfer, Token, Email0, Amount, Note0}, _From, State) ->
    with_user(Token, State,
      fun(UserId) ->
          transfer_funds(UserId, string:lowercase(string:trim(Email0)),
                         Amount, string:trim(Note0), State)
      end);
handle_call({open_savings, Token}, _From, State) ->
    with_user(Token, State, fun(UserId) -> add_savings_account(UserId, State) end);
handle_call({move_funds, Token, FromAccountId, ToAccountId, Amount}, _From, State) ->
    with_user(Token, State,
      fun(UserId) -> move_between_accounts(UserId, FromAccountId, ToAccountId,
                                            Amount, State) end);
handle_call({calculate_zakat, Token, NisabCents}, _From, State) ->
    with_user(Token, State,
      fun(UserId) -> zakat_estimate(UserId, NisabCents, State) end);
handle_call(_Request, _From, State) ->
    {reply, {error, not_found}, State}.

handle_cast(_Message, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVersion, State, _Extra) ->
    {ok, State}.

create_user(Name, Email, Password, State) ->
    Users = maps:get(users, State),
    case find_user_by_email(Email, Users) of
        {ok, _Existing} -> {reply, {error, email_already_registered}, State};
        error ->
            UserId = random_id(),
            AccountId = random_id(),
            CustomerNumber = new_customer_number(Users),
            Salt = crypto:strong_rand_bytes(16),
            User = #{id => UserId, name => Name, email => Email,
                     customer_number => CustomerNumber,
                     salt => Salt,
                     password_hash => password_hash(Password, Salt),
                     account_id => AccountId},
            Account = #{id => AccountId, user_id => UserId,
                        type => current, balance_cents => 0,
                        created_at => timestamp()},
                        {Token, Sessions} = new_session(UserId, maps:get(sessions, State)),
            NewState = State#{users => Users#{UserId => User},
                                                            accounts => (maps:get(accounts, State))#{AccountId => Account},
                                                            sessions => Sessions},
            persist_reply(NewState,
              fun(SavedState) ->
                                    {ok, Token, dashboard_for(UserId, SavedState)}
              end,
              State)
    end.

change_balance(UserId, Amount, Kind, State) when is_integer(Amount), Amount > 0 ->
    User = maps:get(UserId, maps:get(users, State)),
    AccountId = maps:get(account_id, User),
    Accounts = maps:get(accounts, State),
    Account = maps:get(AccountId, Accounts),
    Balance = maps:get(balance_cents, Account),
    case {Kind, Balance >= Amount} of
        {withdrawal, false} -> {reply, {error, insufficient_funds}, State};
        _ ->
            Delta = case Kind of deposit -> Amount; withdrawal -> -Amount end,
            UpdatedAccount = Account#{balance_cents => Balance + Delta},
            Entry = transaction(Kind, AccountId, undefined, Amount, ""),
            NewState = State#{accounts => Accounts#{AccountId => UpdatedAccount},
                              transactions => [Entry | maps:get(transactions, State)]},
            persist_reply(NewState,
              fun(SavedState) -> {ok, dashboard_for(UserId, SavedState)} end,
              State)
    end;
change_balance(_UserId, _Amount, _Kind, State) ->
    {reply, {error, invalid_amount}, State}.

transfer_funds(UserId, Email, Amount, Note, State)
  when is_integer(Amount), Amount > 0, length(Note) =< 120 ->
    case find_user_by_email(Email, maps:get(users, State)) of
        error -> {reply, {error, recipient_not_found}, State};
        {ok, #{id := UserId}} ->
            {reply, {error, cannot_transfer_to_self}, State};
        {ok, Recipient} ->
            Sender = maps:get(UserId, maps:get(users, State)),
            SenderId = maps:get(account_id, Sender),
            RecipientId = maps:get(account_id, Recipient),
            Accounts = maps:get(accounts, State),
            SenderAccount = maps:get(SenderId, Accounts),
            RecipientAccount = maps:get(RecipientId, Accounts),
            SenderBalance = maps:get(balance_cents, SenderAccount),
            case SenderBalance >= Amount of
                false -> {reply, {error, insufficient_funds}, State};
                true ->
                    UpdatedAccounts = Accounts#{
                      SenderId => SenderAccount#{balance_cents => SenderBalance - Amount},
                      RecipientId => RecipientAccount#{
                        balance_cents => maps:get(balance_cents, RecipientAccount) + Amount}},
                    Outgoing = transaction(transfer_sent, SenderId, RecipientId,
                                           Amount, Note),
                    Incoming = transaction(transfer_received, RecipientId, SenderId,
                                           Amount, Note),
                    NewState = State#{accounts => UpdatedAccounts,
                      transactions => [Incoming, Outgoing | maps:get(transactions, State)]},
                    persist_reply(NewState,
                      fun(SavedState) -> {ok, dashboard_for(UserId, SavedState)} end,
                      State)
            end
    end;
transfer_funds(_UserId, _Email, _Amount, _Note, State) ->
    {reply, {error, invalid_amount_or_note}, State}.

add_savings_account(UserId, State) ->
    Accounts = maps:get(accounts, State),
    HasSavings = lists:any(
      fun(Account) -> maps:get(user_id, Account) =:= UserId andalso
                      maps:get(type, Account) =:= mudarabah end,
      maps:values(Accounts)),
    case HasSavings of
        true -> {reply, {error, savings_account_exists}, State};
        false ->
            AccountId = random_id(),
            Account = #{id => AccountId, user_id => UserId, type => mudarabah,
                        balance_cents => 0, created_at => timestamp()},
            NewState = State#{accounts => Accounts#{AccountId => Account}},
            persist_reply(NewState,
              fun(SavedState) -> {ok, dashboard_for(UserId, SavedState)} end,
              State)
    end.

move_between_accounts(UserId, FromId, ToId, Amount, State)
    when is_list(FromId), is_list(ToId), is_integer(Amount), Amount > 0 ->
        Accounts = maps:get(accounts, State),
        case {maps:find(FromId, Accounts), maps:find(ToId, Accounts)} of
                {{ok, From}, {ok, To}} ->
                        IsOwned = maps:get(user_id, From) =:= UserId andalso
                                            maps:get(user_id, To) =:= UserId,
                        case {IsOwned, FromId =:= ToId} of
                                {false, _} -> {reply, {error, account_not_found}, State};
                                {true, true} -> {reply, {error, same_account}, State};
                                {true, false} ->
                                        Balance = maps:get(balance_cents, From),
                                        case Balance >= Amount of
                                                false -> {reply, {error, insufficient_funds}, State};
                                                true ->
                                                        UpdatedAccounts = Accounts#{
                                                            FromId => From#{balance_cents => Balance - Amount},
                                                            ToId => To#{balance_cents =>
                                                                maps:get(balance_cents, To) + Amount}},
                                                        Outgoing = transaction(allocation_out, FromId, ToId,
                                                                               Amount, ""),
                                                        Incoming = transaction(allocation_in, ToId, FromId,
                                                                               Amount, ""),
                                                        NewState = State#{accounts => UpdatedAccounts,
                                                            transactions => [Incoming, Outgoing |
                                                                                             maps:get(transactions, State)]},
                                                        persist_reply(NewState,
                                                            fun(SavedState) -> {ok, dashboard_for(UserId, SavedState)} end,
                                                            State)
                                        end
                        end;
                _ -> {reply, {error, account_not_found}, State}
        end;
move_between_accounts(_UserId, _FromId, _ToId, _Amount, State) ->
        {reply, {error, invalid_amount}, State}.

zakat_estimate(UserId, NisabCents, State)
  when is_integer(NisabCents), NisabCents > 0 ->
    Balance = user_balance(UserId, maps:get(accounts, State)),
    Due = case Balance >= NisabCents of
              true -> (Balance * 25) div 1000;
              false -> 0
          end,
    {ok, #{eligible_balance_cents => Balance,
           nisab_cents => NisabCents,
           estimated_zakat_cents => Due}};
zakat_estimate(_UserId, _NisabCents, _State) ->
    {error, invalid_nisab}.

with_user(Token, State, Action) ->
    Sessions = maps:get(sessions, State),
    case maps:find(Token, Sessions) of
        {ok, #{user_id := UserId, expires_at := Expiry}} ->
            case Expiry >= erlang:system_time(second) of
                true ->
                    case Action(UserId) of
                        {reply, Reply, UpdatedState} -> {reply, Reply, UpdatedState};
                        Reply -> {reply, Reply, State}
                    end;
                false -> {reply, {error, unauthorized},
                          State#{sessions => maps:remove(Token, Sessions)}}
            end;
        error -> {reply, {error, unauthorized}, State}
    end.

dashboard_for(UserId, State) ->
    User = maps:get(UserId, maps:get(users, State)),
    Accounts = [public_account(Account) || Account <-
      maps:values(maps:get(accounts, State)), maps:get(user_id, Account) =:= UserId],
    AccountIds = [maps:get(id, Account) || Account <- Accounts],
    Transactions = [public_transaction(Transaction) || Transaction <-
      lists:sublist([Entry || Entry <- maps:get(transactions, State),
        lists:member(maps:get(account_id, Entry), AccountIds)], 50)],
    #{user => #{name => list_to_binary(maps:get(name, User)),
                email => list_to_binary(maps:get(email, User)),
                customer_number => list_to_binary(maps:get(customer_number, User))},
      accounts => Accounts,
      total_balance_cents => lists:sum([maps:get(balance_cents, Account) ||
                                         Account <- Accounts]),
      transactions => Transactions}.

public_account(Account) ->
        #{id => list_to_binary(maps:get(id, Account)), type => maps:get(type, Account),
      balance_cents => maps:get(balance_cents, Account),
            created_at => list_to_binary(maps:get(created_at, Account))}.

public_transaction(Entry) ->
        #{id => list_to_binary(maps:get(id, Entry)), type => maps:get(type, Entry),
            account_id => list_to_binary(maps:get(account_id, Entry)),
            counterparty_account_id => optional_binary(maps:get(counterparty_account_id, Entry)),
            amount_cents => maps:get(amount_cents, Entry),
            note => list_to_binary(maps:get(note, Entry)),
            created_at => list_to_binary(maps:get(created_at, Entry))}.

optional_binary(undefined) -> null;
optional_binary(Value) -> list_to_binary(Value).

user_balance(UserId, Accounts) ->
    lists:sum([maps:get(balance_cents, Account) || Account <- maps:values(Accounts),
                                                   maps:get(user_id, Account) =:= UserId]).

transaction(Kind, AccountId, CounterpartyId, Amount, Note) ->
    #{id => random_id(), type => Kind, account_id => AccountId,
      counterparty_account_id => CounterpartyId, amount_cents => Amount,
      note => Note, created_at => timestamp()}.

validate_registration(Name, Email, Password) ->
    case {length(Name) >= 2 andalso length(Name) =< 80,
          valid_email(Email), is_list(Password) andalso length(Password) >= 10 andalso
            length(Password) =< 256} of
        {false, _, _} -> {error, invalid_name};
        {_, false, _} -> {error, invalid_email};
        {_, _, false} -> {error, password_too_short};
        _ -> ok
    end.

valid_email(Email) ->
    case string:split(Email, "@", all) of
        [Local, Domain] -> Local =/= [] andalso string:find(Domain, ".") =/= nomatch;
        _ -> false
    end.

find_user_by_email(Email, Users) ->
    case [User || User <- maps:values(Users), maps:get(email, User) =:= Email] of
        [User | _] -> {ok, User};
        [] -> error
    end.

find_user_by_customer_number(CustomerNumber, Users) ->
    case [User || User <- maps:values(Users),
                  maps:get(customer_number, User) =:= CustomerNumber] of
        [User | _] -> {ok, User};
        [] -> error
    end.

assign_customer_numbers(Users) ->
    {Updated, _Taken} = maps:fold(
      fun(UserId, User, {Acc, Taken}) ->
          Existing = maps:get(customer_number, User, undefined),
          CustomerNumber = case is_list(Existing) andalso
                                not maps:is_key(Existing, Taken) of
                               true -> Existing;
                               false -> new_customer_number_from(Taken)
                           end,
          {Acc#{UserId => User#{customer_number => CustomerNumber}},
           Taken#{CustomerNumber => true}}
      end, {#{}, #{}}, Users),
    Updated.

new_customer_number(Users) ->
    Taken = maps:from_list([{maps:get(customer_number, User), true} ||
      User <- maps:values(Users), maps:is_key(customer_number, User)]),
    new_customer_number_from(Taken).

new_customer_number_from(Taken) ->
    Number = 1000000000 +
             (binary:decode_unsigned(crypto:strong_rand_bytes(8)) rem 9000000000),
    CustomerNumber = integer_to_list(Number),
    case maps:is_key(CustomerNumber, Taken) of
        true -> new_customer_number_from(Taken);
        false -> CustomerNumber
    end.

password_hash(Password, Salt) ->
    crypto:pbkdf2_hmac(sha256, unicode:characters_to_binary(Password),
                       Salt, ?PASSWORD_ROUNDS, 32).

password_matches(Password, User) when is_list(Password) ->
    Candidate = password_hash(Password, maps:get(salt, User)),
    crypto:hash_equals(Candidate, maps:get(password_hash, User));
password_matches(_Password, _User) ->
    false.

new_session(UserId, Sessions) ->
    Token = random_id(),
    Session = #{user_id => UserId,
                expires_at => erlang:system_time(second) + ?SESSION_SECONDS},
    {Token, Sessions#{Token => Session}}.

persist_reply(NewState, ReplyFun, OriginalState) ->
    case persist(NewState) of
        ok -> {reply, ReplyFun(NewState), NewState};
        {error, _Reason} -> {reply, {error, persistence_failed}, OriginalState}
    end.

persist(State) ->
    File = maps:get(data_file, State),
    Snapshot = #{users => maps:get(users, State),
                 accounts => maps:get(accounts, State),
                 transactions => maps:get(transactions, State)},
    Binary = term_to_binary(Snapshot, [compressed]),
    TempFile = File ++ ".tmp",
    case filelib:ensure_dir(File) of
        ok ->
            case file:write_file(TempFile, Binary, [raw, binary, sync]) of
                ok -> file:rename(TempFile, File);
                Error -> Error
            end;
        Error -> Error
    end.

load_data(File) ->
    case file:read_file(File) of
        {ok, Binary} ->
            try binary_to_term(Binary, [safe]) of
                #{users := Users, accounts := Accounts, transactions := Transactions} ->
                    {Users, Accounts, Transactions};
                _ -> {#{}, #{}, []}
            catch
                _:_ -> {#{}, #{}, []}
            end;
        _ -> {#{}, #{}, []}
    end.

timestamp() ->
    calendar:system_time_to_rfc3339(erlang:system_time(second), [{unit, second}]).

random_id() ->
    lists:flatten([io_lib:format("~2.16.0b", [Byte]) ||
      <<Byte>> <= crypto:strong_rand_bytes(16)]).