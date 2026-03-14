unit unitdispatcher;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, Graphics, Dialogs, StdCtrls, ExtCtrls,
  ComCtrls, Grids, Spin, comUnit, Types;

type

  //***************************************
  //Production plan obtained by ERP and available in the DB
  // Enumerated: defines the type of the TTask
  TTask_Type  = (Type_Expedition = 1, Type_Delivery, Type_Production, Type_Trash);

  // TBC by a Query to DB
  TProduction_Order = record
    part_type           : Integer;    // Part type { 0, ... 9}
    part_numbers        : Integer;    // Number of parts to be performed
    order_type          : TTask_Type;
  end;

  TArray_Production_Order = array of TProduction_Order; // This array shall be completed by the SQL query
  //***************************************



  //***************************************
  // Dispatcher Execution
  // Enumerated: defines all stages of TTasks
  TStage = (
    Stage_To_Be_Started = 1,
    Stage_GetPart,
    Stage_Unload,
    Stage_To_AR_Out,
    Stage_Clear_Pos_AR,
    Stage_Finished,

    // Novos estados para Produção e Inbound:
    Stage_To_Production,
    Stage_Wait_Input,
    Stage_GetFreePos,
    Stage_Load_AR,
    Stage_Do_Inbound
  );

  // Data structure for holding one Task (OE, OD, OP)
  TTask = record
   task_type           : TTask_Type; // type
   current_operation   : TStage;     // the stage that is currently activ.
   part_type           : Integer;    // Part type { 0, ... 9}
   part_position_AR    : Integer;    // Part Position in AR (if needed)
   part_destination    : Integer;    // Part destination
  end;

  TArray_Task = array of TTask;      // NOTE: this "type" will originate a variable to hold the output from the scheduling ("sequenciador").
  //***************************************


  //***************************************
  // Availability of the resources in the shopfloor:
  TResources = record
   AR_free      : Boolean;    // true (free) or false (busy)
   AR_In_Part   : integer;    // Com uma peça do tipo P={0..9} (0=sem peça)
   AR_Out_Part  : integer;    // Com uma peça do tipo P={0..9} (0=sem peça)
   Robot_1_Part : integer;    // Com uma peça do tipo P={0..9} (0=sem peça)
   Robot_2_Part : integer;    // Com uma peça do tipo P={0..9} (0=sem peça)
   Inbound_free : Boolean;    // true (free) or false (busy)
  end;
  //***************************************



  { TFormDispatcher }
  TFormDispatcher = class(TForm)
    BStart: TButton;
    BExecute: TButton;
    BInitiatilize: TButton;
    ButtonAdicionarStock: TButton;
    ButtonAdicionarOrdem: TButton;
    cbPos: TComboBox;
    cbPecaStock: TComboBox;
    cbTipoOrdem: TComboBox;
    cbPecaPlano: TComboBox;
    GroupBox1: TGroupBox;
    GroupBox2: TGroupBox;
    Memo1: TMemo;
    PageControl1: TPageControl;
    seQtd: TSpinEdit;
    GridStock: TStringGrid;
    GridPlano: TStringGrid;
    StringGrid3: TStringGrid;
    TabSheet1: TTabSheet;
    TabSheet2: TTabSheet;
    Timer1: TTimer;
    procedure BExecuteClick(Sender: TObject);
    procedure BInitiatilizeClick(Sender: TObject);
    procedure BStartClick(Sender: TObject);
    procedure ButtonAdicionarOrdemClick(Sender: TObject);
    procedure ButtonAdicionarStockClick(Sender: TObject);
    procedure FormCreate(Sender: TObject);
    procedure TabSheet1ContextPopup(Sender: TObject; MousePos: TPoint;
      var Handled: Boolean);
    procedure Timer1Timer(Sender: TObject);
  private

  public
    procedure Dispatcher(var tasks:TArray_Task; var idx : integer; shopfloor: TResources );
    procedure Execute_Expedition_Order(var task:TTask; shopfloor: TResources );
    procedure Execute_Inbound_Order(var task:TTask; shopfloor: TResources ); // INBOUND ADICIONADO
    procedure Execute_Production_Order(var task:TTask; shopfloor: TResources ); // Production ADICIONADO
    function GET_AR_Position (Part : integer; Warehouse : array of integer): integer;
    procedure SET_AR_Position (idx : integer; Part : integer; var Warehouse : array of integer);

  end;

const
  //ID for Parts to be used by FIO
  Part_Raw_Blue   = 1;
  Part_Raw_Green  = 2;
  Part_Raw_Grey   = 3;
  Part_Base_Blue  = 4;
  Part_Base_Green = 5;
  Part_Base_Grey  = 6;
  Part_Lid_Blue   = 7;
  Part_Lid_Green  = 8;
  Part_Lid_Grey   = 9;


(* GLOBAL VARIABLES *)
var
  FormDispatcher : TFormDispatcher;

  // Production orders obtained by the ERP (using the SQL Query)
  Production_Orders : TArray_Production_Order;

  // Availability of resources (needs to be updated over time)
  ShopResources : TResources;

  // Tasks that need to be concluded by the MES (expedition, delivery, production and trash).
  ShopTasks     : TArray_Task;

  // Index of the task (from the array "ShopTasks") that is being executed.
  idx_Task_Executing : integer;

  // Status of each cell in the warehouse.
  WAREHOUSE_Parts           : array of integer;         //warehouse parts in each position

implementation

{$R *.lfm}


{ Procedure that checks the status of the resources available on the shop floor }
procedure UpdateResources(var shopfloor: TResources);
var
    resp : array[1..8] of integer;
begin
  {'FactoryIO state',
   'Inbound state',
   'Warehouse_state',
   'Warehouse input conveyor part',
   'Warehouse output conveyor part',
   'Cell 1 part',
   'Cell 2 part',
   'Pick & Place part'
   }
  resp:=M_Get_Factory_Status();

  with shopfloor do
  begin
    Inbound_free := Int(resp[2]) = 1;
    AR_free      := Int(resp[3]) = 1;
    AR_In_Part   := LongInt(resp[4]);
    AR_Out_Part  := LongInt(resp[5]);
    Robot_1_Part := LongInt(resp[6]);
    Robot_2_Part := LongInt(resp[7]);
  end;
end;


{ Procedure that received TArray_Production_Order and converts to TArray_Task
-> INPUT: TArray_Production_Order
-> OUTPUT: TArray_Task
}
procedure SimpleScheduler(var orders: TArray_Production_Order; var tasks:TArray_Task );
var
    current_task     : TTask;
    idx_order        : integer;
    numb_tasks_total : integer = 0;       // total number of tasks created in "tasks"
    numb_same_task   : integer = 0;

begin
  for idx_order:= 0 to Length(orders)-1 do
  begin
      with current_task do
      begin
        numb_same_task    := 0;

        task_type         := orders[idx_order].order_type;
        part_type         := orders[idx_order].part_type;
        current_operation := Stage_To_Be_Started;

        part_position_AR  := -1;  // to be defined later.   STUDENTS MUST CHANGE

        if( part_type < Part_Lid_Blue )then
        begin
             part_destination  := 1;     // if bases (Exit 1 or Cell 1)
        end else
        begin
            part_destination  := 2;     // if bases (Exit 2 or Cell 2)
        end;

        //Create  orders[idx_order].part_numbers of the same TTask for Dispatcher.
        numb_tasks_total :=  Length(tasks);
        SetLength(tasks,  numb_tasks_total + orders[idx_order].part_numbers);
        for numb_same_task := 0 to orders[idx_order].part_numbers-1 do
        begin
            tasks[numb_tasks_total+numb_same_task] := current_task;
        end;
      end;
  end;

end;




// Query DB -> Scheduling -> Connect PLC for Dispatching
procedure TFormDispatcher.BStartClick(Sender: TObject);
var
    result           : integer;
    // production_order : TProduction_Order; // Variável comentada pois só era usada no hardcode
begin
  // ******************************************
  // Query to DB and converts data to structures
  // ...      to be completed by the STUDENT after SQL introduction in INFI.
  // *******************************************


  { ===== INÍCIO DO HARDCODE (Comentado) =====
  // ******************************************
  // Simulating the result of the SQL query:


  SetLength(Production_Orders, 7);                   //Produções Enunciado

  //Expedition

  // 1. Produção de uma tampa cinzenta
  production_order.order_type   := Type_Production;
  production_order.part_numbers := 1;
  production_order.part_type    := Part_Lid_Grey;
  Production_Orders[0]          := production_order;

  // 2. Produção de uma tampa verde
  production_order.order_type   := Type_Production;
  production_order.part_numbers := 1;
  production_order.part_type    := Part_Lid_Green;
  Production_Orders[1]          := production_order;

  // 3. Produção de uma base azul
  production_order.order_type   := Type_Production;
  production_order.part_numbers := 1;
  production_order.part_type    := Part_Base_Blue;
  Production_Orders[2]          := production_order;

  // 4. Expedição de uma tampa verde
  production_order.order_type   := Type_Expedition;
  production_order.part_numbers := 1;
  production_order.part_type    := Part_Lid_Green;
  Production_Orders[3]          := production_order;

  // 5. Expedição de uma base azul
  production_order.order_type   := Type_Expedition;
  production_order.part_numbers := 1;
  production_order.part_type    := Part_Base_Blue;
  Production_Orders[4]          := production_order;

  // 6. Inbound de 1 matéria-prima azul
  production_order.order_type   := Type_Delivery;
  production_order.part_numbers := 1;
  production_order.part_type    := Part_Raw_Blue;
  Production_Orders[5]          := production_order;

  // 7. Inbound de 1 matéria-prima cinzenta
  production_order.order_type   := Type_Delivery;
  production_order.part_numbers := 1;
  production_order.part_type    := Part_Raw_Grey;
  Production_Orders[6]          := production_order;

  (*
  //Base
  production_order.order_type   := Type_Expedition ;
  production_order.part_numbers := 2;
  production_order.part_type    := Part_Base_Blue;    //Blue Base
  Production_Orders[0]          := production_order;  //Saving..

  production_order.order_type   := Type_Expedition ;  //Expedition
  production_order.part_numbers := 2;
  production_order.part_type    := Part_Lid_Green;    //Green Lids
  Production_Orders[1]          := production_order;  //Saving..  *)

  (*
  production_order.order_type     := Type_Delivery ;    //Inbounds
  production_order.part_numbers   := 1;
  production_order.part_type      := 2;                    //Green Raw Material
  Production_Orders[1]            := production_order;

  production_order.order_type     := Type_Production;   //Production
  production_order.part_numbers   := 1;
  production_order.part_type      := 4;                    //Blue Base
  Production_Orders[2]            := production_order;

  production_order.order_type     := Type_Expedition;   //Expedition
  production_order.part_numbers   := 1;
  production_order.part_type      := 4;                    //Green Base
  Production_Orders[4]            := production_order;
  *)
  // ******************************************
  ===== FIM DO HARDCODE ===== }


  // for Scheduling
  idx_Task_Executing := 0;

  //Connecting to PLC
  result := M_connect();

  if (result = 1) then
    BStart.Caption:='Connected to PLC'
  else
  begin
    BStart.Caption:='Start';
    ShowMessage('PLC unavailable. Please try again!');
   end;
end;

procedure TFormDispatcher.ButtonAdicionarOrdemClick(Sender: TObject);
var
  linha, id_peca: integer;
  tipoOrdem, peca: string;
begin
  tipoOrdem := cbTipoOrdem.Text;
  peca := cbPecaPlano.Text;

  // Extrai apenas o primeiro caractere do texto (ex: tira o "1" de "1 - Matéria-Prima")
  id_peca := StrToInt(Copy(peca, 1, 1));

  // A TUA NOVA REGRA DE SEGURANÇA:
  // Se for Produção E a peça for 1, 2 ou 3 (Matérias-Primas)...
  if (tipoOrdem = 'Produção') and (id_peca <= 3) then
  begin
    ShowMessage('Atenção: Não é possível fabricar Matéria-Prima! Por favor, escolha uma Base ou Tampa.');
    Exit; // Pára imediatamente e não adiciona à grelha
  end;

  // Se passou na verificação de segurança, adiciona a linha normalmente
  linha := GridPlano.RowCount;
  GridPlano.RowCount := linha + 1;

  GridPlano.Cells[0, linha] := tipoOrdem;
  GridPlano.Cells[1, linha] := peca;
  GridPlano.Cells[2, linha] := IntToStr(seQtd.Value);
end;

procedure TFormDispatcher.ButtonAdicionarStockClick(Sender: TObject);
var
  linha, i: integer;
  posicaoEscolhida: string;
  jaExiste: boolean;
begin
  posicaoEscolhida := cbPos.Text;
  jaExiste := False;

  // 1. Verificar se a posição já está ocupada na tabela
  // Começamos em 1 para ignorar o cabeçalho da tabela
  for i := 1 to GridStock.RowCount - 1 do
  begin
    if GridStock.Cells[0, i] = posicaoEscolhida then
    begin
      jaExiste := True;
      Break; // Já encontrámos, não vale a pena procurar mais
    end;
  end;

  // 2. Se já existe, mostramos um erro e paramos por aqui
  if jaExiste then
  begin
    ShowMessage('Atenção: A Posição ' + posicaoEscolhida + ' já está ocupada no plano!');
    Exit; // O "Exit" faz o código parar e não adiciona a linha
  end;

  // 3. Se não existe, adicionamos a linha normalmente
  linha := GridStock.RowCount;
  GridStock.RowCount := linha + 1;

  GridStock.Cells[0, linha] := posicaoEscolhida;
  GridStock.Cells[1, linha] := cbPecaStock.Text;
end;

procedure TFormDispatcher.FormCreate(Sender: TObject);
begin
  SetLength(ShopTasks, 0);
  idx_Task_Executing := 0;

  // Formatar a Tabela de Stock
  GridStock.ColCount := 2; // 2 Colunas
  GridStock.RowCount := 1; // Só o cabeçalho para começar
  GridStock.Cells[0, 0] := 'Posição';
  GridStock.Cells[1, 0] := 'Peça';
  GridStock.ColWidths[0] := 60;
  GridStock.ColWidths[1] := 180;

  // Formatar a Tabela do Plano de Produção
  GridPlano.ColCount := 3; // 3 Colunas
  GridPlano.RowCount := 1;
  GridPlano.Cells[0, 0] := 'Tipo Ordem';
  GridPlano.Cells[1, 0] := 'Peça';
  GridPlano.Cells[2, 0] := 'Qtd';
  GridPlano.ColWidths[0] := 90;
  GridPlano.ColWidths[1] := 160;
  GridPlano.ColWidths[2] := 50;

  // Por defeito, selecionar a primeira opção das ComboBoxes
  cbPos.ItemIndex := 0;
  cbPecaStock.ItemIndex := 0;
  cbTipoOrdem.ItemIndex := 0;
  cbPecaPlano.ItemIndex := 0;
  seQtd.Value := 1;
end;

procedure TFormDispatcher.TabSheet1ContextPopup(Sender: TObject;
  MousePos: TPoint; var Handled: Boolean);
begin

end;

procedure TFormDispatcher.Timer1Timer(Sender: TObject);
begin
  BExecuteClick(Self);
end;



(* Hard Code
//Initialization of the MES /week. This procedure run only once per week
procedure TFormDispatcher.BInitiatilizeClick(Sender: TObject);
var
    cel, r: integer;
begin
  // *********************************************************
  // WAREHOUSE MANAGEMENT

  // Initialization of parts in the first column of the warehouse.
  r := M_Initialize(1, Part_Raw_Blue); // 1 Matéria-prima azul (1) posição 1
  sleep(1500); //sleep de 1 segundo e meio nos inicialize e nos inbounds

  r := r + M_Initialize(10, Part_Raw_Green); // 1 Matéria-prima verde (2) posição 10
  sleep(1500);

  r := r + M_Initialize(19, Part_Raw_Grey); // 1 Matéria-prima cinzenta (3) posição 19
  sleep(1500);

  r := r + M_Initialize(28, Part_Lid_Green); // 1 Tampa verde (8) posição 28

  if( r > 4) then
    Memo1.Append('Innitiatialization with errors'); //só podem inicializar no máximo 4 coisas


  //Update the Warehouse according to the previous innitialization

  //Apenas pois o PLC não sabe o que está em cada sítio
  SetLength(WAREHOUSE_Parts, 55);                //Parts in the warehouse   55-1 = 54 to start in 1

  WAREHOUSE_Parts[0] := -1; // Não existe a posição 0

  for  cel := 1 to  Length(WAREHOUSE_Parts)-1 do
  begin
      WAREHOUSE_Parts[cel] := 0;
  end;
  WAREHOUSE_Parts[1]       := Part_Raw_Blue;
  WAREHOUSE_Parts[10]      := Part_Raw_Green;
  WAREHOUSE_Parts[19]      := Part_Raw_Grey;
  WAREHOUSE_Parts[28]      := Part_Lid_Green;


  //Converts ProductionOrders to Tasks (staged activities)
  SimpleScheduler(Production_Orders, ShopTasks);


  // Starting Dispatcher Iterations over time
  Timer1.Enabled:= true;
end;
*)

procedure TFormDispatcher.BInitiatilizeClick(Sender: TObject);
var
  i, pos, part, r: integer;
  tipoOrdemStr: string;
  ordem: TProduction_Order;
begin
  // 1. PREPARAR O ARMAZÉM VIRTUAL (Limpar tudo)
  SetLength(WAREHOUSE_Parts, 55);
  WAREHOUSE_Parts[0] := -1; // Posição 0 não existe
  for i := 1 to Length(WAREHOUSE_Parts)-1 do
    WAREHOUSE_Parts[i] := 0; // Fica tudo a zeros

  // 2. LER A TABELA DE STOCK E INICIALIZAR A FÁBRICA
  Memo1.Append('A carregar o Stock Inicial...');

  // Percorre as linhas do GridStock (começa no 1 para saltar o cabeçalho)
  for i := 1 to GridStock.RowCount - 1 do
  begin
    // Se a linha não estiver preenchida, ignora
    if GridStock.Cells[0, i] = '' then Continue;

    pos := StrToInt(GridStock.Cells[0, i]);

    // TRUQUE: A nossa string é "1 - Matéria-Prima Azul".
    // A função Copy() vai extrair apenas o 1º carácter (o número 1) e converter para Integer!
    part := StrToInt(Copy(GridStock.Cells[1, i], 1, 1));

    r := M_Initialize(pos, part); // Manda o comando para o Factory I/O
    Sleep(1500); // Dá 1.5 segundos para o robô lá colocar a peça

    // Atualiza o nosso "cérebro" a dizer que a peça está lá
    WAREHOUSE_Parts[pos] := part;
  end;

  // 3. LER A TABELA DO PLANO DE PRODUÇÃO (A tua interface!)
  Memo1.Append('A ler o Plano de Produção...');

  // O tamanho do nosso array de ordens passa a ser exatamente o nº de linhas da tabela
  SetLength(Production_Orders, GridPlano.RowCount - 1);

  for i := 1 to GridPlano.RowCount - 1 do
  begin
    if GridPlano.Cells[0, i] = '' then Continue;

    // Traduzir o texto da combobox para os tipos que o programa entende
    tipoOrdemStr := GridPlano.Cells[0, i];
    if tipoOrdemStr = 'Produção' then ordem.order_type := Type_Production
    else if tipoOrdemStr = 'Expedição' then ordem.order_type := Type_Expedition
    else if tipoOrdemStr = 'Inbound' then ordem.order_type := Type_Delivery;

    // Extrai o ID da peça usando o mesmo truque
    ordem.part_type := StrToInt(Copy(GridPlano.Cells[1, i], 1, 1));
    ordem.part_numbers := StrToInt(GridPlano.Cells[2, i]); // Quantidade

    // Guarda no array de ordens (o array começa no índice 0, por isso usamos i-1)
    Production_Orders[i-1] := ordem;
  end;

  // 4. PREPARAR AS TAREFAS E ARRANCAR O MOTOR!
  idx_Task_Executing := 0;

  // Envia as ordens que lemos da grelha para o Scheduler
  SimpleScheduler(Production_Orders, ShopTasks);

  // Ativa a fábrica
  Timer1.Enabled := true;
  Memo1.Append('Fábrica em Automático!');
end;


// get the first position (cell) in AR that contains the "Part"
function TFormDispatcher.GET_AR_Position (Part : integer; Warehouse : array of integer): integer;
var
    i : integer;
begin
  for i := 0 to Length(Warehouse)-1 do
  begin
      if Warehouse[i] = Part then
      begin
          result := i;
          Exit;
      end;
  end;
end;

//Sets the Position of the AR with the "Part" provided
procedure TFormDispatcher.SET_AR_Position (idx : integer; Part : integer; var Warehouse : array of integer);
begin
  Warehouse [ idx ] := Part;
end;




procedure TFormDispatcher.BExecuteClick(Sender: TObject);
begin
  // See the availability of resources
  UpdateResources(ShopResources);


  //Dispatcher executing per cycle.
  if(Length(ShopTasks)>0) then begin
    Dispatcher(ShopTasks, idx_Task_Executing, ShopResources);
  end;
end;



// Global Dispatcher - SIMPLEX
procedure TFormDispatcher.Dispatcher(var tasks:TArray_Task; var idx : integer; shopfloor: TResources );
begin
    case tasks[idx].task_type of

      // Expedition
      Type_Expedition :
      begin
        if(idx < Length(tasks)) then
        begin
          Memo1.Append('Task Expedition');
          Execute_Expedition_Order(tasks[idx], shopfloor);

          // Next Operation to be executed.
          if(tasks[idx].current_operation = Stage_Finished) then
            inc(idx_Task_Executing);
        end;
      end;


      // Production
      Type_Production :
      begin
        if(idx < Length(tasks)) then
        begin
          Memo1.Append('Task Production');
          Execute_Production_Order(tasks[idx], shopfloor);

          // Next Operation to be executed.
          if(tasks[idx].current_operation = Stage_Finished) then
            inc(idx_Task_Executing);
        end;
      end;


      // Inbound
      Type_Delivery :
      begin
        if(idx < Length(tasks)) then
        begin
          Memo1.Append('Task Inbound');
          Execute_Inbound_Order(tasks[idx], shopfloor);

          // Next Operation to be executed.
          if(tasks[idx].current_operation = Stage_Finished) then
            inc(idx_Task_Executing);
        end;
      end;

      // Trash -- NÃO É PARA FAZER !!!
      Type_Trash :
      begin
        //todo
      end;

    end;
end;


// Procedure that executes an expedition order according to SLIDE 19 of T classes.
procedure TFormDispatcher.Execute_Expedition_Order(var task:TTask; shopfloor: TResources );
var
    r : integer;
begin
  //  TStage      = (Stage_To_Be_Started = 1, Stage_GetPart, Stage_Unload, Stage_To_AR_Out, Stage_Clear_Pos_AR, Stage_Finished);   //TbC

  with task do
  begin
     case current_operation of

        // To be Started
        Stage_To_Be_Started:
        begin
           current_operation :=  Stage_GetPart;
        end;

        // Getting a Position from the Warehouse
        Stage_GetPart :
        begin
          if(shopfloor.AR_free) then  //AR is free
          begin
            Part_Position_AR := GET_AR_Position(Part_Type, WAREHOUSE_Parts);
            Memo1.Append(IntToStr(Part_Position_AR));

            if( Part_Position_AR > 0 ) then
            begin
               current_operation :=  Stage_Unload;
            end
            else
            begin
               current_operation :=  Stage_GetPart;
            end;
          end;
        end;

        // Request to unload that part
        Stage_Unload :
        begin
          Memo1.Append('AR Unloading: ' + IntToStr(Part_Position_AR));
          r := M_Unload(Part_Position_AR);

          if ( r = 1 ) then                                 //sucess
             current_operation :=  Stage_To_AR_Out;
        end;

        // Part is in the output conveyor
        Stage_To_AR_Out :
        begin
          if( ShopResources.AR_Out_Part  = Part_Type ) then
          begin
            r := M_Do_Expedition(Part_Destination);          // Expedition

            if( r = 1) then                                  // sucess
             current_operation :=  Stage_Clear_Pos_AR;
          end;
        end;

        //Updated AR (removing the part from the position)
        Stage_Clear_Pos_AR :
        begin
          SET_AR_Position(Part_Position_AR, 0, WAREHOUSE_Parts);
          current_operation :=  Stage_Finished;
        end;

        //Done.
        Stage_Finished :
        begin
          current_operation :=  Stage_Finished;
        end;
      end;
  end;
end;

// Procedure que executa a ordem de inbound.
procedure TFormDispatcher.Execute_Inbound_Order(var task:TTask; shopfloor: TResources );
var
  r : integer;
begin
  with task do
  begin
     case current_operation of

        // 1. Iniciar a tarefa
        Stage_To_Be_Started:
        begin
           current_operation := Stage_Do_Inbound;
        end;

        // 2. Pedir a matéria-prima vinda do exterior
        Stage_Do_Inbound:
        begin
           Memo1.Append('A pedir Inbound da peça: ' + IntToStr(part_type));
           r := M_Do_Inbound(part_type); // Envia comando

           if (r = 1) then // 1 = Comando executado corretamente
             current_operation := Stage_Wait_Input;
        end;

        // 3. Esperar que a peça chegue ao tapete de entrada do armazém
        Stage_Wait_Input:
        begin
           // O status 4 do vetor de fábrica devolve a peça no tapete de entrada
           if (shopfloor.AR_In_Part = part_type) then
             current_operation := Stage_GetFreePos;
        end;

        // 4. Encontrar uma posição livre (valor 0) no array virtual do armazém
        Stage_GetFreePos:
        begin
           if (shopfloor.AR_free) then // Garantir que o armazém não está ocupado
           begin
             part_position_AR := GET_AR_Position(0, WAREHOUSE_Parts); // 0 significa célula vazia

             if (part_position_AR > 0) then
               current_operation := Stage_Load_AR;
           end;
        end;

        // 5. Carregar a peça do tapete para a célula do armazém
        Stage_Load_AR:
        begin
           Memo1.Append('A carregar para posição: ' + IntToStr(part_position_AR));
           r := M_Load(part_position_AR); //

           if (r = 1) then // 1 = Comando válido
           begin
             // Atualizar a nossa memória (array) de que a peça já está na prateleira
             SET_AR_Position(part_position_AR, part_type, WAREHOUSE_Parts);
             current_operation := Stage_Finished;
           end;
        end;

        Stage_Finished:
        begin
           // Fim da tarefa
        end;
     end;
  end;
end;

procedure TFormDispatcher.Execute_Production_Order(var task:TTask; shopfloor: TResources );
var
  r : integer;
  required_raw : integer;
begin
  // 1. Descobrir qual a matéria-prima necessária
  case task.part_type of
    Part_Base_Blue, Part_Lid_Blue:   required_raw := Part_Raw_Blue;
    Part_Base_Green, Part_Lid_Green: required_raw := Part_Raw_Green;
    Part_Base_Grey, Part_Lid_Grey:   required_raw := Part_Raw_Grey;
  else
    required_raw := 0;
  end;

  with task do
  begin
     case current_operation of

        Stage_To_Be_Started:
        begin
           current_operation := Stage_GetPart;
        end;

        // 2. Procurar a matéria-prima no armazém
        Stage_GetPart:
        begin
           if (shopfloor.AR_free) then
           begin
             part_position_AR := GET_AR_Position(required_raw, WAREHOUSE_Parts);
             if (part_position_AR > 0) then
               current_operation := Stage_Unload;
           end;
        end;

        // 3. Fazer o UNLOAD (como tu testaste)
        Stage_Unload:
        begin
           r := M_Unload(part_position_AR);
           if (r = 1) then
             current_operation := Stage_To_AR_Out;
        end;

        // 4. Mandar para PRODUÇÃO (1 ou 2)
        Stage_To_AR_Out:
        begin
           if (shopfloor.AR_Out_Part = required_raw) then
           begin
             SET_AR_Position(part_position_AR, 0, WAREHOUSE_Parts);

             r := M_Do_Production(part_destination);
             if (r = 1) then
               current_operation := Stage_Wait_Input;
           end;
        end;

        // 5. Esperar que a peça final volte
        Stage_Wait_Input:
        begin
           if (shopfloor.AR_In_Part = part_type) then
             current_operation := Stage_GetFreePos;
        end;

        // 6. Procurar um espaço livre (o primeiro 0 que aparecer)
        Stage_GetFreePos:
        begin
           if (shopfloor.AR_free) then
           begin

             part_position_AR := GET_AR_Position(0, WAREHOUSE_Parts);

             if (part_position_AR > 0) then
               current_operation := Stage_Load_AR;
           end;
        end;

        // 7. Fazer o LOAD na nova posição
        Stage_Load_AR:
        begin
           r := M_Load(part_position_AR);
           if (r = 1) then
           begin
             // Atualiza o array com a peça nova
             SET_AR_Position(part_position_AR, part_type, WAREHOUSE_Parts);
             current_operation := Stage_Finished;
           end;
        end;

        Stage_Finished:
        begin
          // Fim da tarefa
        end;

     end;
  end;
end;



end.

