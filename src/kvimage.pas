unit kvimage;

{ Image side of kuvascript: peek at a picture's size and EXIF orientation,
  then produce a JPEG that covers a given cell size, cropped at an anchor.

  Everything works on a plain 8 bit RGB buffer (TKVPixmap) so that a 20 MP
  photo does not need 160 MB the way TFPMemoryImage would. }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Math, FPImage, FPReadJPEG, FPReadPNG, FPWriteJPEG, kvtypes;

type
  EKVImage = class(Exception);

  { RGB, 3 bytes per pixel, row after row. Doubles as a target for the
    fcl-image readers and a source for the JPEG writer. }
  TKVPixmap = class(TFPCustomImage)
  protected
    procedure SetInternalColor(x, y: Integer; const Value: TFPColor); override;
    function GetInternalColor(x, y: Integer): TFPColor; override;
    procedure SetInternalPixel(x, y, Value: Integer); override;
    function GetInternalPixel(x, y: Integer): Integer; override;
  public
    Data: array of Byte;
    procedure SetSize(AWidth, AHeight: Integer); override;
  end;

  TKVImageInfo = record
    Width, Height: Integer;   // as displayed, i.e. after applying Orientation
    Orientation: Integer;     // EXIF orientation 1..8, 1 when absent
    IsJPEG: Boolean;
  end;

{ Reads just enough of the file to know its size and orientation. }
function KVImageInfo(const FileName: string): TKVImageInfo;

{ Writes DestFile: SrcFile scaled to cover TW x TH and cropped at Anchor. }
procedure KVRenderCover(const SrcFile, DestFile: string; TW, TH: Integer;
  Anchor: TKVAnchor; Quality: Integer);

implementation

{ Recent fcl-image (FPC trunk, 3.3.1) rotates JPEGs by their EXIF orientation
  while decoding, 3.2.x does not. Only rotate here when the reader does not,
  or the picture would be turned twice. }
{$IF NOT DECLARED(TExifOrientation)}
  {$DEFINE KV_OWN_ROTATION}
{$ENDIF}

{ ---- TKVPixmap ---------------------------------------------------------- }

procedure TKVPixmap.SetSize(AWidth, AHeight: Integer);
begin
  inherited SetSize(AWidth, AHeight);
  SetLength(Data, AWidth * AHeight * 3);
end;

procedure TKVPixmap.SetInternalColor(x, y: Integer; const Value: TFPColor);
var
  P: Integer;
begin
  P := (y * Width + x) * 3;
  Data[P] := Value.Red shr 8;
  Data[P + 1] := Value.Green shr 8;
  Data[P + 2] := Value.Blue shr 8;
end;

function TKVPixmap.GetInternalColor(x, y: Integer): TFPColor;
var
  P: Integer;
begin
  P := (y * Width + x) * 3;
  Result.Red := (Data[P] shl 8) or Data[P];
  Result.Green := (Data[P + 1] shl 8) or Data[P + 1];
  Result.Blue := (Data[P + 2] shl 8) or Data[P + 2];
  Result.Alpha := alphaOpaque;
end;

procedure TKVPixmap.SetInternalPixel(x, y, Value: Integer);
begin
  // no palette support
end;

function TKVPixmap.GetInternalPixel(x, y: Integer): Integer;
begin
  Result := 0;
end;

{ ---- header peeking -------------------------------------------------------- }

function ReadU16(S: TStream; BigEndian: Boolean): Integer;
var
  B: array[0..1] of Byte;
begin
  S.ReadBuffer(B, 2);
  if BigEndian then
    Result := (B[0] shl 8) or B[1]
  else
    Result := (B[1] shl 8) or B[0];
end;

function ReadU32(S: TStream; BigEndian: Boolean): Cardinal;
var
  B: array[0..3] of Byte;
begin
  S.ReadBuffer(B, 4);
  if BigEndian then
    Result := (Cardinal(B[0]) shl 24) or (B[1] shl 16) or (B[2] shl 8) or B[3]
  else
    Result := (Cardinal(B[3]) shl 24) or (B[2] shl 16) or (B[1] shl 8) or B[0];
end;

{ Orientation tag of the Exif block that starts at the current position of
  S (the byte after "Exif\0\0"), or 1. }
function ExifOrientation(S: TStream; Len: Integer): Integer;
var
  Base: Int64;
  BE: Boolean;
  B: array[0..1] of Byte;
  Off: Cardinal;
  Count, I, Tag, Typ: Integer;
begin
  Result := 1;
  Base := S.Position;
  if Len < 14 then Exit;
  S.ReadBuffer(B, 2);
  if (B[0] = Ord('M')) and (B[1] = Ord('M')) then
    BE := True
  else if (B[0] = Ord('I')) and (B[1] = Ord('I')) then
    BE := False
  else
    Exit;
  if ReadU16(S, BE) <> 42 then Exit;
  Off := ReadU32(S, BE);
  if (Off < 8) or (Off > Cardinal(Len) - 2) then Exit;
  S.Position := Base + Off;
  Count := ReadU16(S, BE);
  for I := 1 to Count do
  begin
    if S.Position + 12 > Base + Len then Exit;
    Tag := ReadU16(S, BE);
    Typ := ReadU16(S, BE);
    ReadU32(S, BE);
    if (Tag = $0112) and (Typ = 3) then
    begin
      Result := ReadU16(S, BE);
      if (Result < 1) or (Result > 8) then Result := 1;
      Exit;
    end;
    S.Seek(4, soCurrent);
  end;
end;

function InfoJPEG(S: TStream): TKVImageInfo;
var
  M, Len, Prec: Integer;
  B: Byte;
  Sig: array[0..5] of Char;
  Next: Int64;
  GotSize: Boolean;
begin
  Result.Orientation := 1;
  Result.IsJPEG := True;
  Result.Width := 0;
  Result.Height := 0;
  GotSize := False;
  S.Position := 2; // after SOI
  while S.Position < S.Size - 4 do
  begin
    S.ReadBuffer(B, 1);
    if B <> $FF then Continue;
    repeat
      S.ReadBuffer(B, 1);
    until B <> $FF;
    M := B;
    if (M = $D8) or (M = $01) or ((M >= $D0) and (M <= $D7)) or (M = 0) then Continue;
    Len := ReadU16(S, True);
    Next := S.Position + Len - 2;
    if (M = $E1) and (Len >= 8) then
    begin
      S.ReadBuffer(Sig, 6);
      if (Sig[0] = 'E') and (Sig[1] = 'x') and (Sig[2] = 'i') and (Sig[3] = 'f') then
        Result.Orientation := ExifOrientation(S, Len - 8);
    end
    else if (M >= $C0) and (M <= $CF) and (M <> $C4) and (M <> $C8) and (M <> $CC) then
    begin
      S.ReadBuffer(B, 1);
      Prec := B;
      Result.Height := ReadU16(S, True);
      Result.Width := ReadU16(S, True);
      GotSize := Prec > 0;
    end
    else if M = $DA then
      Break; // start of scan, no more headers
    if GotSize and (Result.Orientation <> 1) then Break;
    S.Position := Next;
  end;
  if not GotSize then
    raise EKVImage.Create('not a readable JPEG');
end;

function InfoPNG(S: TStream): TKVImageInfo;
var
  Sig: array[0..7] of Byte;
begin
  S.Position := 0;
  S.ReadBuffer(Sig, 8);
  S.Seek(8, soCurrent); // chunk length and "IHDR"
  Result.Width := Integer(ReadU32(S, True));
  Result.Height := Integer(ReadU32(S, True));
  Result.Orientation := 1;
  Result.IsJPEG := False;
end;

function KVImageInfo(const FileName: string): TKVImageInfo;
var
  S: TFileStream;
  Head: array[0..3] of Byte;
  T: Integer;
begin
  S := TFileStream.Create(FileName, fmOpenRead or fmShareDenyWrite);
  try
    try
      if S.Size < 24 then raise EKVImage.Create('file too small to be an image');
      S.ReadBuffer(Head, 4);
      if (Head[0] = $FF) and (Head[1] = $D8) then
        Result := InfoJPEG(S)
      else if (Head[0] = $89) and (Head[1] = Ord('P')) and (Head[2] = Ord('N')) and (Head[3] = Ord('G')) then
        Result := InfoPNG(S)
      else
        raise EKVImage.Create('neither JPEG nor PNG');
    except
      on E: EKVImage do raise EKVImage.CreateFmt('%s: %s', [FileName, E.Message]);
      on E: EReadError do raise EKVImage.CreateFmt('%s: truncated file', [FileName]);
    end;
  finally
    S.Free;
  end;
  if (Result.Width < 1) or (Result.Height < 1) then
    raise EKVImage.CreateFmt('%s: image has no size', [FileName]);
  if Result.Orientation in [5..8] then
  begin
    T := Result.Width;
    Result.Width := Result.Height;
    Result.Height := T;
  end;
end;

{ ---- decoding --------------------------------------------------------------- }

{ Reduce is 1, 2, 4 or 8; JPEGs are then decoded straight to that fraction of
  their size, which is much faster and as good as a box filter. }
function LoadPixmap(const FileName: string; IsJPEG: Boolean; Reduce: Integer): TKVPixmap;
var
  Reader: TFPCustomImageReader;
  S: TFileStream;
begin
  Result := TKVPixmap.Create(0, 0);
  try
    if IsJPEG then
    begin
      Reader := TFPReaderJPEG.Create;
      case Reduce of
        2: TFPReaderJPEG(Reader).Scale := jsHalf;
        4: TFPReaderJPEG(Reader).Scale := jsQuarter;
        8: TFPReaderJPEG(Reader).Scale := jsEighth;
      end;
    end
    else
      Reader := TFPReaderPNG.Create;
    try
      S := TFileStream.Create(FileName, fmOpenRead or fmShareDenyWrite);
      try
        Result.LoadFromStream(S, Reader);
      finally
        S.Free;
      end;
    finally
      Reader.Free;
    end;
  except
    Result.Free;
    raise;
  end;
end;

{$IFDEF KV_OWN_ROTATION}
{ Applies an EXIF orientation (2..8) to Src and frees it. }
function Reorient(Src: TKVPixmap; Orientation: Integer): TKVPixmap;
var
  SW, SH, DW, DH, X, Y, SX, SY: Integer;
  PS, PD: PByte;
begin
  if Orientation = 1 then Exit(Src);
  SW := Src.Width;
  SH := Src.Height;
  if Orientation in [5..8] then
  begin
    DW := SH;
    DH := SW;
  end
  else
  begin
    DW := SW;
    DH := SH;
  end;
  Result := TKVPixmap.Create(DW, DH);
  try
    PD := @Result.Data[0];
    for Y := 0 to DH - 1 do
      for X := 0 to DW - 1 do
      begin
        case Orientation of
          2: begin SX := SW - 1 - X; SY := Y; end;
          3: begin SX := SW - 1 - X; SY := SH - 1 - Y; end;
          4: begin SX := X; SY := SH - 1 - Y; end;
          5: begin SX := Y; SY := X; end;
          6: begin SX := Y; SY := SH - 1 - X; end;
          7: begin SX := SW - 1 - Y; SY := SH - 1 - X; end;
        else
          begin SX := SW - 1 - Y; SY := X; end; // 8
        end;
        PS := @Src.Data[(SY * SW + SX) * 3];
        PD[0] := PS[0];
        PD[1] := PS[1];
        PD[2] := PS[2];
        Inc(PD, 3);
      end;
  except
    Result.Free;
    raise;
  end;
  Src.Free;
end;
{$ENDIF}

{ ---- resampling ------------------------------------------------------------- }

{ Fills Dst (already sized) with the part X0,Y0,CW x CH of Src. Shrinking
  averages every source pixel under a destination pixel (weighted by overlap);
  enlarging in both directions interpolates bilinearly. }
procedure Resample(Src, Dst: TKVPixmap; X0, Y0, CW, CH: Double);
var
  DW, DH, DX, DY, IX, IY, IX0, IX1, IY0, IY1, C, SW, SH: Integer;
  X1, Y1: Integer;
  StepX, StepY, SX0, SX1, SY0, SY1, WX, WY, W: Double;
  Sum: array[0..2] of Double;
  TotalW, FX, FY, A, B, P00, P10, P01, P11: Double;
  PD: PByte;
begin
  DW := Dst.Width;
  DH := Dst.Height;
  SW := Src.Width;
  SH := Src.Height;
  StepX := CW / DW;
  StepY := CH / DH;
  PD := @Dst.Data[0];
  if (StepX < 1) and (StepY < 1) then
  begin
    // bilinear
    for DY := 0 to DH - 1 do
    begin
      FY := Y0 + (DY + 0.5) * StepY - 0.5;
      IY0 := Floor(FY);
      B := FY - IY0;
      Y1 := IY0 + 1;
      if IY0 < 0 then IY0 := 0;
      if Y1 < 0 then Y1 := 0;
      if IY0 > SH - 1 then IY0 := SH - 1;
      if Y1 > SH - 1 then Y1 := SH - 1;
      for DX := 0 to DW - 1 do
      begin
        FX := X0 + (DX + 0.5) * StepX - 0.5;
        IX0 := Floor(FX);
        A := FX - IX0;
        X1 := IX0 + 1;
        if IX0 < 0 then IX0 := 0;
        if X1 < 0 then X1 := 0;
        if IX0 > SW - 1 then IX0 := SW - 1;
        if X1 > SW - 1 then X1 := SW - 1;
        for C := 0 to 2 do
        begin
          P00 := Src.Data[(IY0 * SW + IX0) * 3 + C];
          P10 := Src.Data[(IY0 * SW + X1) * 3 + C];
          P01 := Src.Data[(Y1 * SW + IX0) * 3 + C];
          P11 := Src.Data[(Y1 * SW + X1) * 3 + C];
          PD^ := Round((P00 * (1 - A) + P10 * A) * (1 - B) + (P01 * (1 - A) + P11 * A) * B);
          Inc(PD);
        end;
      end;
    end;
    Exit;
  end;

  for DY := 0 to DH - 1 do
  begin
    SY0 := Y0 + DY * StepY;
    SY1 := SY0 + StepY;
    IY0 := Max(0, Floor(SY0));
    IY1 := Min(SH - 1, Ceil(SY1) - 1);
    for DX := 0 to DW - 1 do
    begin
      SX0 := X0 + DX * StepX;
      SX1 := SX0 + StepX;
      IX0 := Max(0, Floor(SX0));
      IX1 := Min(SW - 1, Ceil(SX1) - 1);
      Sum[0] := 0; Sum[1] := 0; Sum[2] := 0;
      TotalW := 0;
      for IY := IY0 to IY1 do
      begin
        WY := Min(IY + 1, SY1) - Max(IY, SY0);
        if WY <= 0 then Continue;
        for IX := IX0 to IX1 do
        begin
          WX := Min(IX + 1, SX1) - Max(IX, SX0);
          if WX <= 0 then Continue;
          W := WX * WY;
          TotalW := TotalW + W;
          for C := 0 to 2 do
            Sum[C] := Sum[C] + W * Src.Data[(IY * SW + IX) * 3 + C];
        end;
      end;
      if TotalW <= 0 then
      begin
        // degenerate rectangle: take the nearest pixel
        IX := EnsureRange(Floor(SX0), 0, SW - 1);
        IY := EnsureRange(Floor(SY0), 0, SH - 1);
        for C := 0 to 2 do
          Sum[C] := Src.Data[(IY * SW + IX) * 3 + C];
        TotalW := 1;
      end;
      for C := 0 to 2 do
      begin
        PD^ := EnsureRange(Round(Sum[C] / TotalW), 0, 255);
        Inc(PD);
      end;
    end;
  end;
end;

{ ---- the public job -------------------------------------------------------------- }

procedure KVRenderCover(const SrcFile, DestFile: string; TW, TH: Integer;
  Anchor: TKVAnchor; Quality: Integer);
var
  Info: TKVImageInfo;
  Src, Dst: TKVPixmap;
  Scale, CW, CH, X0, Y0: Double;
  Reduce: Integer;
  Writer: TFPWriterJPEG;
  Tmp: string;
begin
  Info := KVImageInfo(SrcFile);

  // decode only as much as the target needs
  Scale := Max(TW / Info.Width, TH / Info.Height);
  Reduce := 1;
  if Info.IsJPEG then
  begin
    if Scale <= 1 / 8 then Reduce := 8
    else if Scale <= 1 / 4 then Reduce := 4
    else if Scale <= 1 / 2 then Reduce := 2;
  end;

  Src := LoadPixmap(SrcFile, Info.IsJPEG, Reduce);
  try
    {$IFDEF KV_OWN_ROTATION}
    Src := Reorient(Src, Info.Orientation);
    {$ENDIF}

    // the part of the picture that covers the target, placed by Anchor
    Scale := Max(TW / Src.Width, TH / Src.Height);
    CW := Min(Src.Width, TW / Scale);
    CH := Min(Src.Height, TH / Scale);
    case Anchor of
      kaTL, kaBL: X0 := 0;
      kaTR, kaBR: X0 := Src.Width - CW;
    else
      X0 := (Src.Width - CW) / 2;
    end;
    case Anchor of
      kaTL, kaTR: Y0 := 0;
      kaBL, kaBR: Y0 := Src.Height - CH;
    else
      Y0 := (Src.Height - CH) / 2;
    end;

    Dst := TKVPixmap.Create(TW, TH);
    try
      Resample(Src, Dst, X0, Y0, CW, CH);
      Writer := TFPWriterJPEG.Create;
      try
        Writer.CompressionQuality := Quality;
        Writer.ProgressiveEncoding := True;
        // write next to the target first so a crash never leaves half a file
        Tmp := DestFile + '.part';
        Dst.SaveToFile(Tmp, Writer);
        if FileExists(DestFile) then DeleteFile(DestFile);
        if not RenameFile(Tmp, DestFile) then
          raise EKVImage.CreateFmt('cannot write %s', [DestFile]);
      finally
        Writer.Free;
      end;
    finally
      Dst.Free;
    end;
  finally
    Src.Free;
  end;
end;

end.
