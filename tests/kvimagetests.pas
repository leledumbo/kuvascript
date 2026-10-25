unit kvimagetests;

{ Run from the repository root: the tests use examples/hello. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, testregistry, FPImage, FPReadJPEG, FPWritePNG, kvtypes, kvimage;

type
  TImageTests = class(TTestCase)
  private
    FTemp: string;
    function Pic(const Name: string): string;
    function WithOrientation(const Src: string; Orientation: Integer): string;
    function Load(const FileName: string): TFPMemoryImage;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure InfoOfPlainJPEG;
    procedure InfoOfPNG;
    procedure InfoAppliesExifOrientation;
    procedure RejectsGarbage;
    procedure RenderHasExactSize;
    procedure AnchorsPickDifferentParts;
    procedure ExifRotationIsApplied;
    procedure UpscalingWorks;
  end;

implementation

procedure TImageTests.SetUp;
begin
  FTemp := GetTempDir + 'kvtests-' + IntToStr(GetProcessID) + PathDelim;
  ForceDirectories(FTemp);
end;

procedure TImageTests.TearDown;
var
  SR: TSearchRec;
begin
  if FindFirst(FTemp + '*', faAnyFile, SR) = 0 then
  begin
    repeat
      DeleteFile(FTemp + SR.Name);
    until FindNext(SR) <> 0;
    FindClose(SR);
  end;
  RemoveDir(FTemp);
end;

function TImageTests.Pic(const Name: string): string;
begin
  Result := 'examples/hello/' + Name;
  AssertTrue('run the tests from the repository root (missing ' + Result + ')', FileExists(Result));
end;

{ Copy of Src with an EXIF block that carries the given orientation. }
function TImageTests.WithOrientation(const Src: string; Orientation: Integer): string;
const
  // "Exif, two zero bytes", TIFF header (big endian, IFD0 at 8), one IFD entry
  // (tag 0x0112, SHORT, count 1, value), no next IFD
  Block: array[0..31] of Byte = (
    $45, $78, $69, $66, 0, 0,
    $4D, $4D, 0, $2A, 0, 0, 0, 8,
    0, 1,
    $01, $12, 0, 3, 0, 0, 0, 1, 0, 0, 0, 0,
    0, 0, 0, 0);
var
  F: TFileStream;
  Data: array of Byte;
  Exif: array[0..31] of Byte;
begin
  F := TFileStream.Create(Src, fmOpenRead);
  try
    SetLength(Data, F.Size);
    F.ReadBuffer(Data[0], F.Size);
  finally
    F.Free;
  end;
  Move(Block, Exif, SizeOf(Exif));
  Exif[25] := Orientation; // low byte of the entry's value
  Result := FTemp + 'exif' + IntToStr(Orientation) + '.jpg';
  F := TFileStream.Create(Result, fmCreate);
  try
    F.WriteBuffer(Data[0], 2);          // SOI
    F.WriteByte($FF);                   // APP1 marker
    F.WriteByte($E1);
    F.WriteByte(0);                     // segment length, includes these 2 bytes
    F.WriteByte(SizeOf(Exif) + 2);
    F.WriteBuffer(Exif, SizeOf(Exif));
    F.WriteBuffer(Data[2], Length(Data) - 2);
  finally
    F.Free;
  end;
end;

function TImageTests.Load(const FileName: string): TFPMemoryImage;
var
  R: TFPReaderJPEG;
begin
  Result := TFPMemoryImage.Create(0, 0);
  R := TFPReaderJPEG.Create;
  try
    Result.LoadFromFile(FileName, R);
  finally
    R.Free;
  end;
end;

procedure TImageTests.InfoOfPlainJPEG;
var
  I: TKVImageInfo;
begin
  I := KVImageInfo(Pic('landscape1.jpg'));
  AssertEquals(1200, I.Width);
  AssertEquals(800, I.Height);
  AssertEquals(1, I.Orientation);
  AssertTrue(I.IsJPEG);
end;

procedure TImageTests.InfoOfPNG;
var
  Img: TFPMemoryImage;
  W: TFPWriterPNG;
  I: TKVImageInfo;
  FN: string;
begin
  // a PNG made on the spot: 3x2 pixels
  FN := FTemp + 'x.png';
  Img := TFPMemoryImage.Create(3, 2);
  W := TFPWriterPNG.Create;
  try
    Img.Colors[0, 0] := colRed;
    Img.SaveToFile(FN, W);
  finally
    W.Free;
    Img.Free;
  end;
  I := KVImageInfo(FN);
  AssertEquals(3, I.Width);
  AssertEquals(2, I.Height);
  AssertFalse(I.IsJPEG);
end;

procedure TImageTests.InfoAppliesExifOrientation;
var
  I: TKVImageInfo;
begin
  I := KVImageInfo(WithOrientation(Pic('landscape1.jpg'), 6));
  AssertEquals(6, I.Orientation);
  AssertEquals('width and height swap for a rotated picture', 800, I.Width);
  AssertEquals(1200, I.Height);
  I := KVImageInfo(WithOrientation(Pic('landscape1.jpg'), 3));
  AssertEquals(1200, I.Width);
end;

procedure TImageTests.RejectsGarbage;
var
  S: TStringList;
begin
  S := TStringList.Create;
  try
    S.Text := 'this is not a picture, but long enough to get past the size check';
    S.SaveToFile(FTemp + 'bad.jpg');
  finally
    S.Free;
  end;
  try
    KVImageInfo(FTemp + 'bad.jpg');
    Fail('expected EKVImage');
  except
    on EKVImage do ; // fine
  end;
end;

procedure TImageTests.RenderHasExactSize;
var
  Img: TFPMemoryImage;
begin
  KVRenderCover(Pic('portrait1.jpg'), FTemp + 'a.jpg', 400, 600, kaC, 90);
  Img := Load(FTemp + 'a.jpg');
  try
    AssertEquals(400, Img.Width);
    AssertEquals(600, Img.Height);
  finally
    Img.Free;
  end;
  // not the same shape: still exactly the requested size
  KVRenderCover(Pic('landscape1.jpg'), FTemp + 'b.jpg', 333, 111, kaC, 80);
  Img := Load(FTemp + 'b.jpg');
  try
    AssertEquals(333, Img.Width);
    AssertEquals(111, Img.Height);
  finally
    Img.Free;
  end;
end;

procedure TImageTests.AnchorsPickDifferentParts;
var
  L, R: TFPMemoryImage;
  C1, C2: TFPColor;
begin
  // landscape source squeezed into a square: the left and right slices differ
  KVRenderCover(Pic('landscape1.jpg'), FTemp + 'l.jpg', 200, 200, kaTL, 95);
  KVRenderCover(Pic('landscape1.jpg'), FTemp + 'r.jpg', 200, 200, kaTR, 95);
  L := Load(FTemp + 'l.jpg');
  R := Load(FTemp + 'r.jpg');
  try
    C1 := L.Colors[100, 100];
    C2 := R.Colors[100, 100];
    AssertTrue('left and right crops should differ', Abs(C1.Red - C2.Red) + Abs(C1.Green - C2.Green) +
      Abs(C1.Blue - C2.Blue) > 3 * 256);
    // the "TL" marker is in the left crop's corner only
    AssertTrue('top left corner of the TL crop holds the white label',
      L.Colors[30, 25].Red > $C000);
  finally
    L.Free;
    R.Free;
  end;
end;

procedure TImageTests.ExifRotationIsApplied;
var
  A, B: TFPMemoryImage;
  P, Q: TFPColor;
begin
  // orientation 3 is a half turn: the top left corner of the plain render is
  // the bottom right corner of the rotated one
  KVRenderCover(Pic('landscape1.jpg'), FTemp + 'plain.jpg', 300, 200, kaC, 95);
  KVRenderCover(WithOrientation(Pic('landscape1.jpg'), 3), FTemp + 'turned.jpg', 300, 200, kaC, 95);
  A := Load(FTemp + 'plain.jpg');
  B := Load(FTemp + 'turned.jpg');
  try
    P := A.Colors[60, 60];
    Q := B.Colors[300 - 1 - 60, 200 - 1 - 60];
    AssertTrue(Format('rotated pixel differs: %d,%d,%d vs %d,%d,%d', [P.Red shr 8, P.Green shr 8,
      P.Blue shr 8, Q.Red shr 8, Q.Green shr 8, Q.Blue shr 8]),
      (Abs(P.Red - Q.Red) < 6 * 256) and (Abs(P.Green - Q.Green) < 6 * 256) and
      (Abs(P.Blue - Q.Blue) < 6 * 256));
    // and a quarter turn swaps the shape: a portrait target needs no letterboxing
    KVRenderCover(WithOrientation(Pic('landscape1.jpg'), 6), FTemp + 'q.jpg', 200, 300, kaC, 90);
  finally
    A.Free;
    B.Free;
  end;
end;

procedure TImageTests.UpscalingWorks;
var
  Img: TFPMemoryImage;
begin
  KVRenderCover(Pic('landscape1.jpg'), FTemp + 'up.jpg', 2000, 1500, kaC, 70);
  Img := Load(FTemp + 'up.jpg');
  try
    AssertEquals(2000, Img.Width);
    AssertEquals(1500, Img.Height);
  finally
    Img.Free;
  end;
end;

initialization
  RegisterTest(TImageTests);

end.
