program kvtests;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  Classes, consoletestrunner, kvparsertests, kvimagetests, kvbuildtests;

type
  TRunner = class(TTestRunner)
  end;

var
  App: TRunner;

begin
  App := TRunner.Create(nil);
  App.Initialize;
  App.Title := 'kuvascript tests';
  App.Run;
  App.Free;
end.
