## Authorization stored procedure optimization
#### Scenario
The Dashboard procedure does a nested call to the auhorization procedure (GetAuthCaseListByUser) to get the list of authorized medical cases for the current user.This file includes the optimization approach for GetAuthCaseListByUser.

### 1.	Temporary Object Optimization
```sql
-- before optimization
DECLARE @AuthCaseList TABLE   
(  
	MedicalCaseId INT
);  

DECLARE @AuthorizedPhysiciansAndLocations TABLE   
(	
	PrimaryPhysicianId  NVARCHAR(50),  
	OrganizationId INT,  
	IsPhysician bit,  
	AccessTypeId int
)

-- after optimization
Eliminated the temporary storage (@AuthCaseList) for list of medical cases.

Table variable @AuthorizedPhysiciansAndLocations converted to #TempTable

CREATE TABLE #AuthorizedPhysiciansAndOrganizations  (
	PrimayPhysicianId  NVARCHAR(50),  
	OrganizationId INT, 
	UserFlag TINYINT
)  
```

### 2.	Applying early-stage filtering to reduce dataset size
Moved the filtering from the main procedure to the nested procedure
```sql
-- before optimization
The filters were applied in the main procedure GetDashboardCases.

-- after optimization
-- prepare the sql statement with filter values from the cases related tables. it should be applied at the initial stage of finding the authorized cases.
IF EXISTS (SELECT 1 FROM #FilterValues WHERE Fields = 'Organization')
	SET @sqlbasicfilter = @sqlbasicfilter + ' AND cpd.OrganizationId in (SELECT [IntValues] FROM #FilterValues WHERE Fields = ''Organization'')'
IF EXISTS (SELECT 1 FROM #FilterValues WHERE Fields = 'MedicalCaseId')
	SET @sqlbasicfilter = @sqlbasicfilter + ' AND cpd.MedicalCaseId in (SELECT [IntValues] FROM #FilterValues WHERE Fields = ''MedicalCaseId'')'
IF EXISTS (SELECT 1 FROM #FilterValues WHERE Fields = 'PrimaryPhysician')
	SET @sqlbasicfilter = @sqlbasicfilter + ' AND cpd.PrimayPhysicianId in (SELECT [Values] FROM #FilterValues WHERE Fields = ''PrimaryPhysician'')'
```
### 3. Functions (in the filter condition) executing row by row
Increament @EndDate by 1 day to avoid the date conversion of eventdatetime in the where clause
```sql
-- before optimization
 WHERE    
	(@StartDate IS NULL OR CAST(cpd.EventDateTime AS DATE) >= @StartDate) AND   
	(@EndDate IS NULL OR CAST(cpd.EventDateTime AS DATE) <= @EndDate) 

-- after optimization
IF @EndDate IS NOT NULL 
	SET @EndDate = DATEADD(day, 1, @EndDate)

SELECT
.
.
WHERE 
	(@StartDate IS NULL OR cpd.EventDateTime >= @StartDate) AND   
	(@EndDate IS NULL OR cpd.EventDateTime < @EndDate) 
```

### 3. Splitting complex OR conditions into optimized execution branches 
Building conditional JOINs dynamically based on authorization type so that unnecessary table joins can be avoided keeping the query as short as possible for final execution.

```sql
-- before optimization
--Step 1 execution - get list of medical cases by current user's authorization  
INSERT INTO @AuthCaseList  
SELECT cpd.MedicalCaseId  
FROM CasePlanningDetails cpd  
INNER JOIN @AuthorizedPhysiciansAndLocations auth  ON (auth.PrimaryPhysicianId IS NULL OR cpd.PrimaryPhysicianId = auth.PrimaryPhysicianId )  
	AND (auth.OrganizationId IS NULL OR cpd.OrganizationId = auth.OrganizationId )  
	AND auth.AccessTypeId != 7
WHERE    
	(@StartDate IS NULL OR CAST(cpd.EventDateTime AS DATE) >= @StartDate) AND   
	(@EndDate IS NULL OR CAST(cpd.EventDateTime AS DATE) <= @EndDate) 
GROUP BY cpd.MedicalCaseId  

--Step 2: Get list of cases WHERE current user's authorized Physicians are present as additional Physicians   
.
.

-- Step 3: Get the case list based on the authorization applicable for Special approver role
.
.

 IF @FilterValues IS NULL  
 BEGIN   
  SELECT MedicalCaseId FROM @AuthCaseList GROUP BY MedicalCaseId;  
 END   

-- after optimization
SET @sql = 'SELECT t.MedicalCaseId FROM (SELECT MedicalCaseId FROM MedicalCases WHERE 1=2'

--Step 1 - get list of cases for Physician role (include cases for secondary Physicians)
IF EXISTS (SELECT VALUE FROM string_split(@authaccessTypes,',') WHERE VALUE in (1, 2, 3))
BEGIN
	SET @sql = @sql  + ' UNION
	SELECT cpd.MedicalCaseId  
	FROM CasePlanningDetails cpd  
	INNER JOIN #AuthorizedPhysiciansAndOrganizations auth ON cpd.OrganizationId = auth.OrganizationId 
	WHERE auth.UserFlag = 1 AND 
	(@StartDate IS NULL OR cpd.EventDateTime >= @StartDate) AND   
	(@EndDate IS NULL OR cpd.EventDateTime < @EndDate) 
	AND cpd.PrimayPhysicianId = @UserId'+@sqlbasicfilter+ 
	' UNION
	SELECT cpd.MedicalCaseId  
	FROM CasePlanningDetails cpd  
	INNER JOIN #AuthorizedPhysiciansAndOrganizations auth ON cpd.OrganizationId = auth.OrganizationId 
	INNER JOIN CaseAdditionalPhysicians cap ON cpd.PlanningDetailId = cap.PlanningDetailId AND cap.IsActive = 1
	WHERE auth.UserFlag = 1 AND 
	(@StartDate IS NULL OR cpd.EventDateTime >= @StartDate) AND   
	(@EndDate IS NULL OR cpd.EventDateTime < @EndDate) 
	AND cap.AdditionalPhysicianId = @UserId'+@sqlbasicfilter
END
ELSE IF EXISTS (SELECT VALUE FROM string_split(@authaccessTypes,',') WHERE VALUE not in (1, 2, 3, 7))
BEGIN
	--get list of cases where logged in user is not Physician but present as secondary Physician
	SET @sql = @sql  + ' UNION
	SELECT cpd.MedicalCaseId  
	FROM CasePlanningDetails cpd  
	INNER JOIN CaseAdditionalPhysicians cap ON cpd.PlanningDetailId = cap.PlanningDetailId AND cap.IsActive = 1
	WHERE 
	(@StartDate IS NULL OR cpd.EventDateTime >= @StartDate) AND   
	(@EndDate IS NULL OR cpd.EventDateTime < @EndDate) 
	AND cap.AdditionalPhysicianId = @UserId'+@sqlbasicfilter
END

--Step 2 - get cases for non-Physician users
IF EXISTS (SELECT VALUE FROM string_split(@authaccessTypes,',') WHERE VALUE not in (1, 2, 3, 7))
BEGIN
	.
	.
END	
END

--Step 3 - get list of cases for special approver role
IF EXISTS (SELECT VALUE FROM string_split(@authaccessTypes,',') WHERE VALUE in (7))
BEGIN
	.
	.
END
SET @sql = @sql+') t'

SET @sql = @sql+@sqlfilter
--print @sql
EXEC sp_executesql @sql, N'@UserId NVARCHAR(50), @StartDate DATE, @EndDate DATE', @UserId=@UserId, @StartDate=@StartDate, @EndDate=@EndDate

```
