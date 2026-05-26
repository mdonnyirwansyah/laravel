<?php

use App\Models\User;
use Illuminate\Support\Facades\Route;

Route::get('/', function () {
    return view('welcome');
});

Route::get('/user', function () {
    return response()->json([
        'data' => User::paginate(10)
    ]);
});
